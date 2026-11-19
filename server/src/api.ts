import type { DeviceRow, Env, Prefs } from "./env";
import { encryptToken, hashSecret, newDeviceSecret, verifySecret, b64encode } from "./crypto";
import { fetchUid, UntappdAuthError } from "./untappd";
import { log, safeErr } from "./log";

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
const err = (status: number, error: string, headers?: Record<string, string>) => json({ error }, status, headers);

const PREF_KEYS = ["toast", "comment", "tag", "friend"] as const;
const DEFAULT_PREFS: Prefs = { toast: true, comment: true, tag: true, friend: true };
const MAX_BODY = 8 * 1024;

class BadRequest extends Error {}

async function readBody(req: Request): Promise<Record<string, unknown>> {
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

async function rateLimited(env: Env, req: Request, now: number): Promise<boolean> {
  const limit = parseInt(env.REGISTER_LIMIT_PER_HOUR ?? "10", 10);
  const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
  const key = b64encode(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip))).slice(0, 22); // IP not stored
  const window = Math.floor(now / 3_600_000);
  const row = await env.DB.prepare(
    "INSERT INTO rate_limits (key, window_start, count) VALUES (?, ?, 1) ON CONFLICT(key, window_start) DO UPDATE SET count = count + 1 RETURNING count",
  )
    .bind(key, window)
    .first<{ count: number }>();
  return (row?.count ?? 1) > limit;
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
  if (await rateLimited(env, req, now)) return err(429, "rate limited", { "retry-after": "3600" });
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

  const id = crypto.randomUUID();
  const secret = newDeviceSecret();
  const sealed = await encryptToken(env, id, token);
  const cap = parseInt(env.MAX_DEVICES_PER_UID ?? "10", 10);
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO users (uid, created_at) VALUES (?, ?)").bind(uid, now),
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
  log("device_registered", { device: id.slice(0, 8) });
  return json({ device_id: id, device_secret: secret });
}

async function patch(req: Request, env: Env, id: string, now: number): Promise<Response> {
  const dev = await authDevice(env, req, id);
  if (dev instanceof Response) return dev;
  let b: Record<string, unknown>;
  const sets: string[] = ["last_seen_at = ?"];
  const vals: unknown[] = [now];
  try {
    b = await readBody(req);
    if (b.apns_token !== undefined) (sets.push("apns_token = ?"), vals.push(vApns(b.apns_token)));
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
      const s = await encryptToken(env, id, token);
      sets.push("token_enc = ?", "dek_enc = ?", "key_version = ?");
      vals.push(s.token_enc, s.dek_enc, s.key_version);
    }
  } catch (e) {
    if (e instanceof BadRequest) return err(400, e.message);
    throw e;
  }
  await env.DB.prepare(`UPDATE devices SET ${sets.join(", ")} WHERE id = ?`).bind(...vals, id).run();
  return json({ ok: true });
}

async function del(req: Request, env: Env, id: string): Promise<Response> {
  const dev = await authDevice(env, req, id);
  if (dev instanceof Response) return dev.status === 404 ? new Response(null, { status: 204 }) : dev;
  await env.DB.prepare("DELETE FROM devices WHERE id = ?").bind(id).run();
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
