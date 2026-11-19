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
  last_counts: string | null;
  next_poll_at: number | null;
  fail_count: number;
  last_seen: number;
}

/** Users with >=1 device whose turn it is. No writes. */
export async function dueUsers(env: Env, now: number): Promise<UserRow[]> {
  const { results } = await env.DB.prepare(
    `SELECT u.uid, u.marker, u.last_counts, u.next_poll_at, u.fail_count, MAX(d.last_seen_at) AS last_seen
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

const RISE_KEYS = ["toasts", "comments", "friends", "others"] as const;
const rose = (prev: U.Counts, cur: U.Counts) => RISE_KEYS.some((k) => cur[k] > prev[k]);

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

export async function pollUser(env: Env, deps: PollDeps, u: UserRow): Promise<void> {
  const { results: devices } = await env.DB.prepare("SELECT * FROM devices WHERE uid = ? ORDER BY last_seen_at DESC")
    .bind(u.uid)
    .all<DeviceRow>();

  const prev: U.Counts | null = u.last_counts ? JSON.parse(u.last_counts) : null;
  let counts: U.Counts | null = null;
  let fetched: Awaited<ReturnType<typeof U.fetchNotifications>> | null = null;
  let token: string | null = null;

  // Use the most-recently-seen device's token; drop devices whose token Untappd rejects.
  const live: DeviceRow[] = [];
  for (const d of devices) {
    if (counts) { live.push(d); continue; }
    let t: string;
    try {
      t = await decryptToken(env, d);
    } catch (e) {
      log("decrypt_failed", { device: d.id.slice(0, 8), error: safeErr(e) });
      await deleteDevice(env, d.id); // undecryptable (e.g. lost master key): device must re-register
      continue;
    }
    try {
      const needBaseline = u.marker === null || prev === null;
      if (needBaseline) {
        fetched = await U.fetchNotifications(t);
        counts = fetched.counts;
      } else {
        counts = await U.pollCounts(t);
        if (rose(prev!, counts)) fetched = await U.fetchNotifications(t);
      }
      token = t;
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
  if (!counts) {
    // No usable device left.
    await env.DB.prepare("DELETE FROM users WHERE uid = ? AND NOT EXISTS (SELECT 1 FROM devices WHERE uid = ?)").bind(u.uid, u.uid).run();
    return;
  }
  void token;

  const upd: Record<string, unknown> = {};
  if (u.fail_count !== 0 || u.next_poll_at !== null) Object.assign(upd, { fail_count: 0, next_poll_at: null });

  if (fetched) {
    const { items, marker } = U.newItemsSince(fetched.items, u.marker);
    if (u.marker === null || prev === null) {
      log("baseline", { uid: u.uid }); // first poll: record, push nothing
    } else if (items.length) {
      await pushItems(env, deps, live, items, counts.unified);
    }
    if (marker !== u.marker) upd.marker = marker;
  }
  const countsJson = JSON.stringify(counts);
  if (countsJson !== u.last_counts) upd.last_counts = countsJson;
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

async function pushItems(env: Env, deps: PollDeps, devices: DeviceRow[], items: U.NotificationItem[], badge: number) {
  for (const item of items) {
    const m = U.formatMessage(item);
    if (!m) continue;
    const payload = {
      aps: {
        alert: { body: m.body },
        badge,
        sound: "default",
        "thread-id": m.checkinId ? `checkin-${m.checkinId}` : "friends",
      },
      retappd: { type: m.type, ...(m.checkinId ? { checkin_id: m.checkinId } : {}), actor: m.actor },
    };
    await Promise.all(
      devices.map(async (d) => {
        if (!allowed(JSON.parse(d.prefs), m.type)) return;
        const r = await deps.apns.send(d, payload);
        if (r === "unregistered") {
          log("apns_unregistered_device_deleted", { device: d.id.slice(0, 8) });
          await deleteDevice(env, d.id);
        } else if (r === "error") log("apns_error", { device: d.id.slice(0, 8) });
      }),
    );
  }
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
