import type { DeviceRow, Env, Prefs } from "./env";
import { CryptoAuthError, decryptToken, rewrapBatch } from "./crypto";
import { type ApnsSender } from "./apns";
import * as U from "./untappd";
import { log, safeErr, uidTag } from "./log";

const CONCURRENCY = 25;
const WARN_USERS_PER_RUN = 500; // above this, raise POLL_SHARDS (see README)
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
  const shards = Math.max(1, parseInt(String(env.POLL_SHARDS ?? "1"), 10) || 1);
  const due = results.filter((u) => {
    const period = (now - u.last_seen >= STALE_MS ? STALE_EVERY_MIN : 1) * shards;
    return u.uid % period === minute % period;
  });
  if (due.length > WARN_USERS_PER_RUN) log("over_capacity", { due: due.length, shards });
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

interface Event {
  at: number;
  type: U.FormattedMessage["type"];
  checkinId?: number;
  actor: string;
  body: string;
}

const MAX_PUSHES = 5; // per device per poll; beyond that the oldest collapse into one summary
const FRIEND_SKEW_MS = 60_000; // Untappd vs server clock allowance for the friend baseline

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
  const rot = devices.length ? Math.floor(now / 60_000) % devices.length : 0;
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
      if (!baseline && U.unreadActivity(p.counts) > 0) fetched = await U.fetchNotifications(t);
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
    upd.marker = String(now);
    upd.marker_keys = null;
    upd.friend_marker = String(Math.max(now - FRIEND_SKEW_MS, maxReq));
    log("baseline", { user: await uidTag(env, u.uid) });
  } else {
    const events: Event[] = [];
    const wf = Number(u.friend_marker);
    const newReqs = polled.requests.filter((r) => r.at > wf);
    for (const r of newReqs) events.push({ at: r.at, ...U.formatFriendRequest(r) });
    if (newReqs.length) upd.friend_marker = String(Math.max(...newReqs.map((r) => r.at)));

    if (fetched) {
      // Each unread unit (toast/comment/other) is at most one item event, so the newest K unhandled items are
      // the new ones; anything else unhandled was read in another app. No dependence on poll timing.
      const k = U.unreadActivity(fetched.counts); // pre-clear counts of the fetch's own envelope
      const marker = Number(u.marker);
      const seen = new Set<string>(u.marker_keys ? JSON.parse(u.marker_keys) : []);
      const candidates = U.newItemsSince(fetched.items, marker, seen, now - MAX_ITEM_AGE_MS);
      for (const i of candidates.slice(-k)) events.push({ at: U.itemTime(i), ...U.formatMessage(i)! });
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
  await Promise.all(
    devices.map(async (d) => {
      const prefs = JSON.parse(d.prefs) as Prefs;
      let mine = events.filter((e) => allowed(prefs, e.type));
      const payloads: object[] = [];
      if (mine.length > MAX_PUSHES) {
        const collapsed = mine.length - (MAX_PUSHES - 1);
        payloads.push({ aps: { alert: { body: `${collapsed} more notifications` }, badge, sound: "default" } });
        mine = mine.slice(collapsed);
      }
      for (const e of mine) {
        payloads.push({
          aps: {
            alert: { body: e.body },
            badge,
            sound: "default",
            "thread-id": e.checkinId ? `checkin-${e.checkinId}` : "friends",
          },
          retappd: { type: e.type, ...(e.checkinId ? { checkin_id: e.checkinId } : {}), actor: e.actor },
        });
      }
      for (const payload of payloads) {
        const r = await deps.apns.send(d, payload); // sequential so they arrive in order
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

/** Daily: drop devices unseen for 30 days, users with no devices, old rate-limit rows; rewrap keys. */
export async function dailyCleanup(env: Env, now: number) {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM devices WHERE last_seen_at < ?").bind(now - 30 * 86_400_000),
    env.DB.prepare("DELETE FROM users WHERE NOT EXISTS (SELECT 1 FROM devices d WHERE d.uid = users.uid)"),
  ]);
  const r = await rewrapBatch(env);
  if (r.rewrapped || r.failed) log("rewrap", r);
}

/** Hourly: drop expired rate-limit windows. */
export async function cleanRateLimits(env: Env, now: number) {
  await env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?").bind(Math.floor(now / 3_600_000) - 1).run();
}
