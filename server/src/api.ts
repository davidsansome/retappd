import { intVar, type DeviceRow, type Env, type Prefs } from "./env";
import { encryptToken, hashSecret, keyedHash, newDeviceSecret, verifySecret } from "./crypto";
import { fetchUid, pollCounts, UntappdAuthError } from "./untappd";
import { BASELINE_SKEW_MS } from "./poll";
import { log, safeErr } from "./log";

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
const err = (status: number, error: string, headers?: Record<string, string>) => json({ error }, status, headers);

const PREF_KEYS = ["toast", "comment", "tag", "friend"] as const;
const DEFAULT_PREFS: Prefs = { toast: true, comment: true, tag: true, friend: true };
const MAX_BODY = 8 * 1024;

class BadRequest extends Error {}

async function readBody(req: Request): Promise<Record<string, unknown>> {
  const cl = Number(req.headers.get("content-length"));
  if (Number.isFinite(cl) && cl > MAX_BODY) throw new BadRequest("body too large");
  const text = await req.text();
  if (text.length > MAX_BODY) throw new BadRequest("body too large");
  let v: unknown;
  try {
    v = JSON.parse(text || "{}");
  } catch {
    throw new BadRequest("invalid JSON");
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new BadRequest("body must be an object");
  return v as Record<string, unknown>;
}

function str(v: unknown, field: string, re: RegExp, max: number): string {
  if (typeof v !== "string" || v.length > max || !re.test(v)) throw new BadRequest(`invalid ${field}`);
  return v;
}
const vToken = (v: unknown) => str(v, "untappd_token", /^[\x21-\x7e]{8,512}$/, 512);
const vApns = (v: unknown) => str(v, "apns_token", /^[0-9a-fA-F]{64,200}$/, 200).toLowerCase();
const vEnv = (v: unknown) => {
  if (v !== "production" && v !== "sandbox") throw new BadRequest("invalid apns_env");
  return v;
};
const vVersion = (v: unknown) => str(v, "app_version", /^[\x20-\x7e]{1,64}$/, 64);
function vPrefs(v: unknown, base: Prefs): Prefs {
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new BadRequest("invalid prefs");
  const out = { ...base };
  for (const k of PREF_KEYS) {
    const x = (v as any)[k];
    if (x === undefined) continue;
    if (typeof x !== "boolean") throw new BadRequest("invalid prefs");
    out[k] = x;
  }
  return out;
}

/** Client key for rate limiting: IPv6 collapsed to its /64, then HMACed so raw IPs are never stored. */
export function ipPrefix(ip: string): string {
  const mapped = /(?:^|:)ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(ip); // IPv4-mapped IPv6
  if (mapped) return mapped[1];
  if (!ip.includes(":")) return ip;
  const [head, tail = ""] = ip.split("::");
  const h = head ? head.split(":") : [];
  const t = tail ? tail.split(":") : [];
  const groups = ip.includes("::") ? [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill("0"), ...t] : h;
  return groups.slice(0, 4).map((g) => g.toLowerCase().replace(/^0+(?=.)/, "")).join(":");
}

/** Fixed-window counter in D1. Returns true if `limit` is exceeded. */
async function overLimit(env: Env, key: string, limit: number, now: number): Promise<boolean> {
  const window = Math.floor(now / 3_600_000);
  const row = await env.DB.prepare(
    "INSERT INTO rate_limits (key, window_start, count) VALUES (?, ?, 1) ON CONFLICT(key, window_start) DO UPDATE SET count = count + 1 RETURNING count",
  )
    .bind(key, window)
    .first<{ count: number }>();
  return (row?.count ?? 1) > limit;
}

const ipLimited = async (env: Env, req: Request, now: number) =>
  overLimit(
    env,
    "ip:" + (await keyedHash(env, "ip", ipPrefix(req.headers.get("cf-connecting-ip") ?? "unknown"))),
    intVar(env.REGISTER_LIMIT_PER_HOUR, 10),
    now,
  );

/**
 * APNs token takeover rule (M1): a registration (POST, or PATCH changing apns_token) replaces any other row holding
 * the same APNs token, whichever uid owns it (legitimate cases: reinstall, or an account switch where the old
 * DELETE failed). To bound abuse, only CROSS-UID replacements are limited, to 3 per hour per APNs token. Same-uid
 * re-registration is unlimited, so nobody can lock a victim out by burning the budget and repeated sign-out/in works.
 */
const tokenLimited = async (env: Env, apns: string, now: number) =>
  overLimit(env, "tok:" + (await keyedHash(env, "apns", apns)), 3, now);

async function pruneUsers(env: Env, uids: number[]) {
  for (const uid of new Set(uids))
    await env.DB.prepare("DELETE FROM users WHERE uid = ? AND NOT EXISTS (SELECT 1 FROM devices WHERE uid = ?)").bind(uid, uid).run();
}

async function authDevice(env: Env, req: Request, id: string): Promise<DeviceRow | Response> {
  const row = await env.DB.prepare("SELECT * FROM devices WHERE id = ?").bind(id).first<DeviceRow>();
  if (!row) return err(404, "unknown device");
  const m = /^Bearer ([A-Za-z0-9_-]{20,100})$/.exec(req.headers.get("authorization") ?? "");
  if (!m || !(await verifySecret(m[1], row.secret_hash))) return err(401, "unauthorized");
  return row;
}

async function verifyOrResponse(token: string): Promise<number | Response> {
  try {
    return await fetchUid(token);
  } catch (e) {
    if (e instanceof UntappdAuthError) return err(401, "untappd rejected the token");
    log("verify_failed", { error: safeErr(e) });
    return err(502, "could not verify token with untappd");
  }
}

async function register(req: Request, env: Env, now: number): Promise<Response> {
  if (await ipLimited(env, req, now)) return err(429, "rate limited", { "retry-after": "3600" });
  let b: Record<string, unknown>;
  let token: string, apns: string, apnsEnv: "production" | "sandbox", prefs: Prefs, version: string | null;
  try {
    b = await readBody(req);
    token = vToken(b.untappd_token);
    apns = vApns(b.apns_token);
    apnsEnv = vEnv(b.apns_env);
    prefs = b.prefs === undefined ? DEFAULT_PREFS : vPrefs(b.prefs, DEFAULT_PREFS);
    version = b.app_version === undefined ? null : vVersion(b.app_version);
  } catch (e) {
    if (e instanceof BadRequest) return err(400, e.message);
    throw e;
  }
  const uid = await verifyOrResponse(token);
  if (uid instanceof Response) return uid;

  const { results: holders } = await env.DB.prepare("SELECT DISTINCT uid FROM devices WHERE apns_token = ?").bind(apns).all<{ uid: number }>();
  if (holders.some((h) => h.uid !== uid) && (await tokenLimited(env, apns, now))) return err(429, "rate limited", { "retry-after": "3600" });
  const id = crypto.randomUUID();
  const secret = newDeviceSecret();
  const sealed = await encryptToken(env, id, uid, token);
  const cap = intVar(env.MAX_DEVICES_PER_UID, 10);
  // Baseline at registration (cheap, side-effect free call) so activity before the first poll isn't swallowed.
  let marker: string | null = null;
  let friendMarker: string | null = null;
  if (!(await env.DB.prepare("SELECT 1 FROM users WHERE uid = ?").bind(uid).first())) {
    try {
      const p = await pollCounts(token);
      marker = String(now - BASELINE_SKEW_MS);
      friendMarker = String(Math.max(now - BASELINE_SKEW_MS, ...p.requests.map((r) => r.at)));
    } catch {
      // the first scheduled poll baselines instead
    }
  }
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO users (uid, created_at, marker, friend_marker) VALUES (?, ?, ?, ?)").bind(uid, now, marker, friendMarker),
    // Re-registration of the same physical device must not leave a duplicate push target.
    env.DB.prepare("DELETE FROM devices WHERE apns_token = ?").bind(apns),
    env.DB.prepare(
      `INSERT INTO devices (id, uid, secret_hash, apns_token, apns_env, prefs, token_enc, dek_enc, key_version, app_version, created_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(id, uid, await hashSecret(secret), apns, apnsEnv, JSON.stringify(prefs), sealed.token_enc, sealed.dek_enc, sealed.key_version, version, now, now),
    // Evict oldest beyond the cap.
    env.DB.prepare(
      "DELETE FROM devices WHERE uid = ? AND id NOT IN (SELECT id FROM devices WHERE uid = ? ORDER BY last_seen_at DESC, created_at DESC LIMIT ?)",
    ).bind(uid, uid, cap),
  ]);
  await pruneUsers(env, holders.map((h) => h.uid));
  log("device_registered", { device: id.slice(0, 8) });
  return json({ device_id: id, device_secret: secret });
}

async function patch(req: Request, env: Env, id: string, now: number): Promise<Response> {
  const dev = await authDevice(env, req, id);
  if (dev instanceof Response) return dev;
  let b: Record<string, unknown>;
  let takeover: string | null = null;
  const sets: string[] = ["last_seen_at = ?"];
  const vals: unknown[] = [now];
  try {
    b = await readBody(req);
    if (b.apns_token !== undefined) {
      const t = vApns(b.apns_token);
      sets.push("apns_token = ?");
      vals.push(t);
      if (t !== dev.apns_token) takeover = t;
    }
    if (b.apns_env !== undefined) (sets.push("apns_env = ?"), vals.push(vEnv(b.apns_env)));
    if (b.app_version !== undefined) (sets.push("app_version = ?"), vals.push(vVersion(b.app_version)));
    if (b.prefs !== undefined) {
      sets.push("prefs = ?");
      vals.push(JSON.stringify(vPrefs(b.prefs, JSON.parse(dev.prefs))));
    }
    if (b.untappd_token !== undefined) {
      const token = vToken(b.untappd_token);
      const uid = await verifyOrResponse(token);
      if (uid instanceof Response) return uid;
      if (uid !== dev.uid) return err(401, "token belongs to a different account");
      const s = await encryptToken(env, id, dev.uid, token);
      sets.push("token_enc = ?", "dek_enc = ?", "key_version = ?");
      vals.push(s.token_enc, s.dek_enc, s.key_version);
    }
  } catch (e) {
    if (e instanceof BadRequest) return err(400, e.message);
    throw e;
  }
  let holders: { uid: number }[] = [];
  const stmts: D1PreparedStatement[] = [];
  if (takeover) {
    holders = (await env.DB.prepare("SELECT DISTINCT uid FROM devices WHERE apns_token = ? AND id != ?").bind(takeover, id).all<{ uid: number }>()).results;
    if (holders.some((h) => h.uid !== dev.uid) && (await tokenLimited(env, takeover, now))) return err(429, "rate limited", { "retry-after": "3600" });
    stmts.push(env.DB.prepare("DELETE FROM devices WHERE apns_token = ? AND id != ?").bind(takeover, id));
  }
  stmts.push(env.DB.prepare(`UPDATE devices SET ${sets.join(", ")} WHERE id = ?`).bind(...vals, id));
  await env.DB.batch(stmts);
  await pruneUsers(env, holders.map((h) => h.uid));
  return json({ ok: true });
}

async function del(req: Request, env: Env, id: string): Promise<Response> {
  const dev = await authDevice(env, req, id);
  if (dev instanceof Response) return dev.status === 404 ? new Response(null, { status: 204 }) : dev;
  await env.DB.prepare("DELETE FROM devices WHERE id = ?").bind(id).run();
  await pruneUsers(env, [dev.uid]);
  return new Response(null, { status: 204 });
}

export async function handleRequest(req: Request, env: Env, now = Date.now()): Promise<Response> {
  const url = new URL(req.url);
  try {
    if (url.pathname === "/v1/devices" && req.method === "POST") return await register(req, env, now);
    const m = /^\/v1\/devices\/([0-9a-f-]{36})$/.exec(url.pathname);
    if (m && req.method === "PATCH") return await patch(req, env, m[1], now);
    if (m && req.method === "DELETE") return await del(req, env, m[1]);
    return err(404, "not found");
  } catch (e) {
    log("request_error", { error: safeErr(e) });
    return err(500, "internal error");
  }
}
