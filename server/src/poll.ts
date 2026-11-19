import type { DeviceRow, Env, Prefs } from "./env";
import { CryptoAuthError, decryptToken, rewrapBatch } from "./crypto";
import { type ApnsSender } from "./apns";
import * as U from "./untappd";
import { log, safeErr, uidTag } from "./log";

const CONCURRENCY = 25;
const WARN_USERS_PER_RUN = 500; // above this, raise POLL_SHARDS (see README)
const MAX_ITEMS_PER_POLL = 100; // sanity cap on notification items examined (and so pushes sent) per user per poll
const MAX_ITEM_AGE_MS = 24 * 3_600_000; // safety cap for the re-toast overcount case
const STALE_MS = 7 * 86_400_000;
const STALE_EVERY_MIN = 5;
const BACKOFF_BASE_S = 60;
const BACKOFF_MAX_S = 3600;

export interface PollDeps {
  apns: ApnsSender;
  now: number;
}

interface UserRow {
  uid: number;
  marker: string | null;
  marker_keys: string | null;
  friend_marker: string | null;
  next_poll_at: number | null;
  fail_count: number;
  last_seen: number;
}

/**
 * Users with >=1 device whose turn it is. No writes. Schedule is stable per user: a user is polled when
 * `minute % period == uid % period`, period = POLL_SHARDS (default 1: every minute), times 5 for users
 * unseen for 7 days. Correctness never depends on cadence (new items are found by unread count, not by time).
 */
/** Effective poll period in minutes: POLL_SHARDS, times 5 for users unseen for 7 days. */
export function periodMin(env: Env, lastSeen: number, now: number): number {
  const shards = Math.max(1, parseInt(String(env.POLL_SHARDS ?? "1"), 10) || 1);
  return (now - lastSeen >= STALE_MS ? STALE_EVERY_MIN : 1) * shards;
}

export async function dueUsers(env: Env, now: number): Promise<UserRow[]> {
  const { results } = await env.DB.prepare(
    `SELECT u.uid, u.marker, u.marker_keys, u.friend_marker, u.next_poll_at, u.fail_count, MAX(d.last_seen_at) AS last_seen
     FROM users u JOIN devices d ON d.uid = u.uid
     WHERE u.next_poll_at IS NULL OR u.next_poll_at <= ?
     GROUP BY u.uid ORDER BY u.uid`,
  )
    .bind(now)
    .all<UserRow>();
  const minute = Math.floor(now / 60_000);
  const due = results.filter((u) => {
    const period = periodMin(env, u.last_seen, now);
    return u.uid % period === minute % period;
  });
  if (due.length > WARN_USERS_PER_RUN) log("over_capacity", { due: due.length });
  return due;
}

export async function runPoll(env: Env, deps: PollDeps): Promise<void> {
  const users = await dueUsers(env, deps.now);
  let i = 0;
  const worker = async () => {
    while (i < users.length) {
      const u = users[i++];
      try {
        await pollUser(env, deps, u);
      } catch (e) {
        log("poll_error", { user: await uidTag(env, u.uid), error: safeErr(e) });
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, users.length) }, worker));
}

async function setState(env: Env, uid: number, f: Record<string, unknown>) {
  const cols = Object.keys(f);
  await env.DB.prepare(`UPDATE users SET ${cols.map((c) => `${c} = ?`).join(", ")} WHERE uid = ?`)
    .bind(...cols.map((c) => f[c]), uid)
    .run();
}

async function backoff(env: Env, deps: PollDeps, u: UserRow, e: unknown) {
  const n = u.fail_count + 1;
  let secs = Math.min(BACKOFF_BASE_S * 2 ** (n - 1), BACKOFF_MAX_S);
  if (e instanceof U.UntappdError && e.retryAfterSec) secs = Math.min(Math.max(secs, e.retryAfterSec), 6 * 3600);
  await setState(env, u.uid, { fail_count: n, next_poll_at: deps.now + secs * 1000 });
  log("backoff", { user: await uidTag(env, u.uid), n, secs });
}

async function deleteDevice(env: Env, d: { id: string; uid: number }) {
  await env.DB.prepare("DELETE FROM devices WHERE id = ?").bind(d.id).run();
  // Drop the user row (and its watermarks) as soon as its last device is gone.
  await env.DB.prepare("DELETE FROM users WHERE uid = ? AND NOT EXISTS (SELECT 1 FROM devices WHERE uid = ?)").bind(d.uid, d.uid).run();
}

/** New activity units in an item: its users[] entries after the marker (a repeat by one user is one entry). */
function units(i: U.NotificationItem, marker: number, seen: Set<string>): number {
  const key = U.itemKey(i);
  const n = (i.users ?? []).filter((x) => {
    const t = Date.parse(x.created_at ?? "") || U.itemTime(i);
    return t > marker || (t === marker && !seen.has(key));
  }).length;
  return Math.max(1, n);
}

/**
 * Candidates (oldest first) -> the items to push. Spend K newest-first. The newest item is always eligible;
 * older ones are vetoed if older than `veto` (0 = no veto) (a user commenting twice is 2 units but 1 entry, so K can still
 * overcount; the window only trims such extras, the marker decides what is new). k = 0 pushes nothing.
 */
export function selectNew(candidates: U.NotificationItem[], k: number, marker: number, seen: Set<string>, veto: number) {
  const out: U.NotificationItem[] = [];
  let remaining = k;
  for (let idx = candidates.length - 1; idx >= 0 && remaining > 0; idx--) {
    const i = candidates[idx];
    if (idx !== candidates.length - 1 && U.itemTime(i) < veto) continue;
    out.push(i);
    remaining -= units(i, marker, seen);
  }
  return out.reverse();
}

interface Event {
  at: number;
  type: U.FormattedMessage["type"];
  checkinId?: number;
  actor: string;
  body: string;
}

export const BASELINE_SKEW_MS = 60_000; // Untappd vs server clock allowance for baselines

export async function pollUser(env: Env, deps: PollDeps, u: UserRow): Promise<void> {
  const { now } = deps;
  const { results: devices } = await env.DB.prepare("SELECT * FROM devices WHERE uid = ? ORDER BY last_seen_at DESC")
    .bind(u.uid)
    .all<DeviceRow>();

  let polled: Awaited<ReturnType<typeof U.pollCounts>> | null = null;
  let fetched: Awaited<ReturnType<typeof U.fetchNotifications>> | null = null;
  const live: DeviceRow[] = [];
    // Never fetch the list on the baseline poll: reading it clears the user's unread counts.
  const baseline = u.marker === null || u.friend_marker === null;

  // Rotate which device's token is used each minute so every device's token gets exercised eventually;
  // devices whose token Untappd rejects are dropped.
  const period = periodMin(env, u.last_seen, now);
  const rot = devices.length ? Math.floor(Math.floor(now / 60_000) / period) % devices.length : 0;
  for (const d of [...devices.slice(rot), ...devices.slice(0, rot)]) {
    if (polled) { live.push(d); continue; }
    let t: string;
    try {
      t = await decryptToken(env, d);
    } catch (e) {
      if (e instanceof CryptoAuthError) {
        // Genuine AEAD failure (wrong/lost key, tampered row): unreadable for good, device must re-register.
        log("decrypt_auth_failed", { device: d.id.slice(0, 8) });
        await deleteDevice(env, d);
        continue;
      }
      // Config problem (missing/invalid master key, unknown key_version): never delete, skip this user.
      log("decrypt_config_error", { device: d.id.slice(0, 8), error: safeErr(e) });
      return;
    }
    try {
      const p = await U.pollCounts(t);
      // Reading the list marks everything read in the official app too, so only do it if something is unread.
      if (!baseline && U.unreadActivity(p.counts) > 0) fetched = await fetchAllUnhandled(t, u, deps.now);
      polled = p;
      live.push(d);
    } catch (e) {
      if (e instanceof U.UntappdAuthError) {
        log("auth_error_device_deleted", { device: d.id.slice(0, 8) });
        await deleteDevice(env, d);
        continue;
      }
      await backoff(env, deps, u, e);
      return;
    }
  }
  if (!polled) return; // every device was dropped; the user row went with the last one

  const upd: Record<string, unknown> = {};
  if (u.fail_count !== 0 || u.next_poll_at !== null) Object.assign(upd, { fail_count: 0, next_poll_at: null });

  if (baseline) {
    // First poll: record watermarks, push nothing. Existing activity and pending requests count as seen.
    const maxReq = polled.requests.reduce((m, r) => Math.max(m, r.at), 0);
    upd.marker = String(now - BASELINE_SKEW_MS);
    upd.marker_keys = null;
    upd.friend_marker = String(Math.max(now - BASELINE_SKEW_MS, maxReq));
    log("baseline", { user: await uidTag(env, u.uid) });
  } else {
    const events: Event[] = [];
    const wf = Number(u.friend_marker);
    const newReqs = polled.requests.filter((r) => r.at > wf);
    for (const r of newReqs) events.push({ at: r.at, ...U.formatFriendRequest(r) });
    if (newReqs.length) upd.friend_marker = String(Math.max(...newReqs.map((r) => r.at)));

    if (fetched) {
      // K = unread units (each toast/comment/other). One item can hold several units (aggregation), so walk
      // newest-first spending K by each item's new users[] entries. Items beyond K were read elsewhere.
      const k = U.unreadActivity(fetched.counts); // pre-clear counts of the fetch's own envelope
      const marker = Number(u.marker);
      const seen = new Set<string>(u.marker_keys ? JSON.parse(u.marker_keys) : []);
      const candidates = U.newItemsSince(fetched.items, marker, seen, now - MAX_ITEM_AGE_MS);
      // No veto after errors (u.fail_count is the pre-reset value): the gap is unbounded and nothing was read in between.
      const veto = u.fail_count > 0 ? 0 : now - 3 * periodMin(env, u.last_seen, now) * 60_000 - 5 * 60_000;
      for (const i of selectNew(candidates, k, marker, seen, veto)) events.push({ at: U.itemTime(i), ...U.formatMessage(i)! });
      if (candidates.length) {
        // Everything unhandled is now handled, pushed or not.
        const newest = U.itemTime(candidates[candidates.length - 1]);
        const keys = candidates.filter((i) => U.itemTime(i) === newest).map(U.itemKey);
        upd.marker = String(newest);
        upd.marker_keys = JSON.stringify(newest === marker ? [...seen, ...keys] : keys);
      }
    }
    if (events.length) {
      events.sort((a, b) => a.at - b.at);
      // Badge: pre-clear unified_count from the notifications call, else from the pending call.
      await pushEvents(env, deps, live, events, (fetched ?? polled).counts.unified);
    }
  }
  if (Object.keys(upd).length) await setState(env, u.uid, upd);
}

function allowed(prefs: Prefs, type: string): boolean {
  switch (type) {
    case "toast": return prefs.toast;
    case "comment": return prefs.comment;
    case "tag": case "comment_tag": return prefs.tag;
    case "friend_request": return prefs.friend;
    default: return false;
  }
}

async function pushEvents(env: Env, deps: PollDeps, devices: DeviceRow[], events: Event[], badge: number) {
  // One push per event, however many. Devices in parallel; sequential within a device to keep order.
  await Promise.all(
    devices.map(async (d) => {
      const prefs = JSON.parse(d.prefs) as Prefs;
      for (const e of events) {
        if (!allowed(prefs, e.type)) continue;
        const payload = {
          aps: {
            alert: { body: e.body },
            badge,
            sound: "default",
            "thread-id": e.checkinId ? `checkin-${e.checkinId}` : "friends",
          },
          retappd: { type: e.type, ...(e.checkinId ? { checkin_id: e.checkinId } : {}), actor: e.actor },
        };
        const r = await deps.apns.send(d, payload);
        if (r === "unregistered") {
          log("apns_unregistered_device_deleted", { device: d.id.slice(0, 8) });
          await deleteDevice(env, d);
          return;
        }
        if (r === "error") log("apns_error", { device: d.id.slice(0, 8) });
      }
    }),
  );
}

/**
 * First page, then further pages while the unread count K says there are more new items than found so far,
 * the last page was full and still reached back to the marker. Capped at MAX_ITEMS_PER_POLL.
 * A failing later page is tolerated: the counts are already cleared, so push what we have.
 */
async function fetchAllUnhandled(token: string, u: UserRow, now: number) {
  const first = await U.fetchNotifications(token);
  const k = U.unreadActivity(first.counts);
  const marker = Number(u.marker);
  const seen = new Set<string>(u.marker_keys ? JSON.parse(u.marker_keys) : []);
  const items = [...first.items];
  let page = first.items;
  while (
    U.newItemsSince(items, marker, seen, now - MAX_ITEM_AGE_MS).reduce((n, i) => n + units(i, marker, seen), 0) < k &&
    page.length >= U.PAGE_SIZE &&
    U.itemTime(page[page.length - 1]) >= marker
  ) {
    if (items.length >= MAX_ITEMS_PER_POLL) {
      log("item_cap_hit", { cap: MAX_ITEMS_PER_POLL });
      break;
    }
    try {
      page = (await U.fetchNotifications(token, items.length)).items;
    } catch (e) {
      log("page_fetch_failed", { error: safeErr(e) });
      break;
    }
    const keys = new Set(items.map(U.itemKey));
    items.push(...page.filter((i) => !keys.has(U.itemKey(i)))); // paging while items move can repeat one
  }
  return { items, counts: first.counts };
}

/** Daily: drop devices unseen for 30 days, users with no devices, old rate-limit rows; rewrap keys. */
export async function dailyCleanup(env: Env, now: number) {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM devices WHERE last_seen_at < ?").bind(now - 30 * 86_400_000),
    env.DB.prepare("DELETE FROM users WHERE NOT EXISTS (SELECT 1 FROM devices d WHERE d.uid = users.uid)"),
  ]);
  const r = await rewrapBatch(env);
  if (r.rewrapped || r.failed || r.deleted) log("rewrap", r);
}

/** Hourly: drop expired rate-limit windows. */
export async function cleanRateLimits(env: Env, now: number) {
  await env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?").bind(Math.floor(now / 3_600_000) - 1).run();
}
