import type { DeviceRow, Env, Prefs } from "./env";
import { decryptToken, rewrapBatch } from "./crypto";
import { type ApnsSender } from "./apns";
import * as U from "./untappd";
import { log, safeErr } from "./log";

const CONCURRENCY = 25;
const MAX_USERS_PER_RUN = 500; // keeps subrequests well under limits; above this, users are sharded across minutes
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
  friend_marker: string | null;
  next_poll_at: number | null;
  fail_count: number;
  last_seen: number;
}

/** Users with >=1 device whose turn it is. No writes. */
export async function dueUsers(env: Env, now: number): Promise<UserRow[]> {
  const { results } = await env.DB.prepare(
    `SELECT u.uid, u.marker, u.friend_marker, u.next_poll_at, u.fail_count, MAX(d.last_seen_at) AS last_seen
     FROM users u JOIN devices d ON d.uid = u.uid
     WHERE u.next_poll_at IS NULL OR u.next_poll_at <= ?
     GROUP BY u.uid ORDER BY u.uid`,
  )
    .bind(now)
    .all<UserRow>();
  const minute = Math.floor(now / 60_000);
  // Stale users (no heartbeat for 7 days) are polled every 5 min, staggered by uid; stateless.
  let due = results.filter((u) => now - u.last_seen < STALE_MS || u.uid % STALE_EVERY_MIN === minute % STALE_EVERY_MIN);
  if (due.length > MAX_USERS_PER_RUN) {
    const shards = Math.ceil(due.length / MAX_USERS_PER_RUN);
    log("sharding", { due: due.length, shards });
    due = due.filter((u) => u.uid % shards === minute % shards);
  }
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
        log("poll_error", { uid: u.uid, error: safeErr(e) });
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
  log("backoff", { uid: u.uid, n, secs });
}

async function deleteDevice(env: Env, id: string) {
  await env.DB.prepare("DELETE FROM devices WHERE id = ?").bind(id).run();
}

interface Event {
  at: number;
  type: U.FormattedMessage["type"];
  checkinId?: number;
  actor: string;
  body: string;
}

const MAX_PUSHES = 5; // per device per poll; beyond that the oldest collapse into one summary
const LOOKBACK_MS = 90_000; // poll interval slack, see below

export async function pollUser(env: Env, deps: PollDeps, u: UserRow): Promise<void> {
  const { now } = deps;
  const { results: devices } = await env.DB.prepare("SELECT * FROM devices WHERE uid = ? ORDER BY last_seen_at DESC")
    .bind(u.uid)
    .all<DeviceRow>();

  let polled: Awaited<ReturnType<typeof U.pollCounts>> | null = null;
  let fetched: Awaited<ReturnType<typeof U.fetchNotifications>> | null = null;
  const live: DeviceRow[] = [];
  const stale = now - u.last_seen >= STALE_MS;
  // Never fetch the list on the baseline poll: reading it clears the user's unread counts.
  const baseline = u.marker === null || u.friend_marker === null;

  // Use the most-recently-seen device's token; drop devices whose token Untappd rejects.
  for (const d of devices) {
    if (polled) { live.push(d); continue; }
    let t: string;
    try {
      t = await decryptToken(env, d);
    } catch (e) {
      log("decrypt_failed", { device: d.id.slice(0, 8), error: safeErr(e) });
      await deleteDevice(env, d.id); // undecryptable (e.g. lost master key): device must re-register
      continue;
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
        await deleteDevice(env, d.id);
        continue;
      }
      await backoff(env, deps, u, e);
      return;
    }
  }
  if (!polled) {
    await env.DB.prepare("DELETE FROM users WHERE uid = ? AND NOT EXISTS (SELECT 1 FROM devices WHERE uid = ?)").bind(u.uid, u.uid).run();
    return;
  }

  const upd: Record<string, unknown> = {};
  if (u.fail_count !== 0 || u.next_poll_at !== null) Object.assign(upd, { fail_count: 0, next_poll_at: null });

  if (baseline) {
    // First poll: record watermarks, push nothing. Existing activity and pending requests count as seen.
    const maxReq = polled.requests.reduce((m, r) => Math.max(m, r.at), 0);
    upd.marker = String(Math.max(now, Number(u.marker ?? 0)));
    upd.friend_marker = String(Math.max(now, maxReq));
    log("baseline", { uid: u.uid });
  } else {
    const events: Event[] = [];
    const wf = Number(u.friend_marker);
    const newReqs = polled.requests.filter((r) => r.at > wf);
    for (const r of newReqs) events.push({ at: r.at, ...U.formatFriendRequest(r) });
    if (newReqs.length) upd.friend_marker = String(Math.max(...newReqs.map((r) => r.at)));

    if (fetched) {
      // Threshold = max(watermark, previous poll time). We don't store poll times (no write per idle poll),
      // but polls run every minute (5 for stale users), so "previous poll" ~ now - cadence. That keeps items
      // that were read in another app between polls (counts back to 0, watermark untouched) from being
      // pushed late. After errors the previous successful poll was further back, so widen by the backoff.
      const cadence = (stale ? STALE_EVERY_MIN : 1) * 60_000;
      const gap = u.fail_count > 0 ? Math.min(BACKOFF_BASE_S * 2 ** u.fail_count, BACKOFF_MAX_S) * 1000 : 0;
      const threshold = Math.max(Number(u.marker), now - cadence - LOOKBACK_MS - gap);
      const items = U.newItemsSince(fetched.items, threshold);
      for (const i of items) {
        const m = U.formatMessage(i)!;
        events.push({ at: U.itemTime(i), ...m });
      }
      if (items.length) upd.marker = String(Math.max(...items.map(U.itemTime)));
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
          await deleteDevice(env, d.id);
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
    env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?").bind(Math.floor(now / 3_600_000) - 2),
  ]);
  const r = await rewrapBatch(env);
  if (r.rewrapped || r.failed) log("rewrap", r);
}
