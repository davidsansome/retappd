import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleRequest } from "../src/api";
import { decryptToken } from "../src/crypto";
import { APNS_TOKEN, mockFetch, req, resetDb, testEnv, untappdMock } from "./helpers";

const env = testEnv();
let u = untappdMock();
const body = (o: object = {}) => ({ untappd_token: "good-token-1234", apns_token: APNS_TOKEN, apns_env: "sandbox", prefs: { toast: true, comment: false, tag: true, friend: true }, app_version: "1.2 (34)", ...o });
const call = (r: Request, now = 1_000_000) => handleRequest(r, env, now);
const bearer = (s: string) => ({ authorization: `Bearer ${s}` });

async function register(o: object = {}) {
  const res = await call(req("POST", "/v1/devices", body(o)));
  return { res, data: (await res.clone().json()) as any };
}

beforeEach(async () => {
  await resetDb(env);
  u = untappdMock();
  mockFetch(u);
});
afterEach(() => vi.unstubAllGlobals());

describe("POST /v1/devices", () => {
  it("registers, binds uid, stores encrypted token and only the secret hash", async () => {
    const { res, data } = await register();
    expect(res.status).toBe(200);
    expect(data.device_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(data.device_secret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const row = await env.DB.prepare("SELECT * FROM devices").first<any>();
    expect(row.uid).toBe(42);
    expect(JSON.stringify(row)).not.toContain("good-token-1234");
    expect(JSON.stringify(row)).not.toContain(data.device_secret);
    expect(await decryptToken(env, row)).toBe("good-token-1234");
    expect(JSON.parse(row.prefs).comment).toBe(false);
    expect((await env.DB.prepare("SELECT * FROM users").first<any>()).marker).toBe(String(1_000_000 - 60_000)); // baselined at registration
  });

  it("401 when Untappd rejects the token", async () => {
    u.authOk = false;
    const { res } = await register();
    expect(res.status).toBe(401);
    expect((await env.DB.prepare("SELECT count(*) c FROM devices").first<any>()).c).toBe(0);
  });

  it("400 on bad bodies", async () => {
    for (const bad of [{ apns_token: "xyz" }, { apns_env: "dev" }, { untappd_token: "" }, { prefs: { toast: "yes" } }, { untappd_token: undefined }]) {
      expect((await register(bad)).res.status).toBe(400);
    }
    const r = await call(new Request("https://t.example/v1/devices", { method: "POST", body: "{nope" }));
    expect(r.status).toBe(400);
  });

  it("rate limits per IP", async () => {
    for (let i = 0; i < 10; i++) expect((await register({ apns_token: String(i).repeat(64) })).res.status).toBe(200);
    expect((await register({ apns_token: "e".repeat(64) })).res.status).toBe(429);
    // another IP is unaffected
    const other = await call(req("POST", "/v1/devices", body({ apns_token: "f".repeat(64) }), { "cf-connecting-ip": "9.9.9.9" }));
    expect(other.status).toBe(200);
  });

  it("caps devices per uid, evicting the oldest", async () => {
    const small = testEnv({ MAX_DEVICES_PER_UID: "3", REGISTER_LIMIT_PER_HOUR: "100" });
    const ids: string[] = [];
    for (let i = 0; i < 4; i++) {
      const r = await handleRequest(req("POST", "/v1/devices", body({ apns_token: String(i).repeat(64) })), small, 1000 + i);
      ids.push(((await r.json()) as any).device_id);
    }
    const { results } = await env.DB.prepare("SELECT id FROM devices").all<any>();
    expect(results.map((r) => r.id).sort()).toEqual(ids.slice(1).sort());
  });

  it("replaces a device that re-registers the same APNs token", async () => {
    await register();
    await register();
    expect((await env.DB.prepare("SELECT count(*) c FROM devices").first<any>()).c).toBe(1);
  });
});

describe("PATCH /v1/devices/:id", () => {
  it("heartbeat refreshes last_seen; prefs merge; apns fields update", async () => {
    const { data } = await register();
    const r = await call(req("PATCH", `/v1/devices/${data.device_id}`, { prefs: { comment: true }, apns_env: "production" }, bearer(data.device_secret)), 5_000_000);
    expect(await r.json()).toEqual({ ok: true });
    const row = await env.DB.prepare("SELECT * FROM devices").first<any>();
    expect(row.last_seen_at).toBe(5_000_000);
    expect(JSON.parse(row.prefs)).toEqual({ toast: true, comment: true, tag: true, friend: true });
    expect(row.apns_env).toBe("production");
    const hb = await call(req("PATCH", `/v1/devices/${data.device_id}`, {}, bearer(data.device_secret)), 6_000_000);
    expect(hb.status).toBe(200);
    expect((await env.DB.prepare("SELECT last_seen_at s FROM devices").first<any>()).s).toBe(6_000_000);
  });

  it("401 with wrong or missing secret, 404 unknown", async () => {
    const { data } = await register();
    expect((await call(req("PATCH", `/v1/devices/${data.device_id}`, {}, bearer("A".repeat(43)))).catch(() => null))?.status).toBe(401);
    expect((await call(req("PATCH", `/v1/devices/${data.device_id}`, {}))).status).toBe(401);
    expect((await call(req("PATCH", `/v1/devices/${crypto.randomUUID()}`, {}, bearer(data.device_secret)))).status).toBe(404);
  });

  it("re-verifies a new untappd token; different uid -> 401", async () => {
    const { data } = await register();
    u.uid = 43;
    const r = await call(req("PATCH", `/v1/devices/${data.device_id}`, { untappd_token: "other-token-999" }, bearer(data.device_secret)));
    expect(r.status).toBe(401);
    u.uid = 42;
    const ok = await call(req("PATCH", `/v1/devices/${data.device_id}`, { untappd_token: "other-token-999" }, bearer(data.device_secret)));
    expect(ok.status).toBe(200);
    const row = await env.DB.prepare("SELECT * FROM devices").first<any>();
    expect(await decryptToken(env, row)).toBe("other-token-999");
  });

  it("400 on invalid fields", async () => {
    const { data } = await register();
    expect((await call(req("PATCH", `/v1/devices/${data.device_id}`, { apns_env: "x" }, bearer(data.device_secret)))).status).toBe(400);
  });
});

describe("DELETE /v1/devices/:id", () => {
  it("deletes with the right secret, 204 if already gone, 401 with wrong secret", async () => {
    const { data } = await register();
    expect((await call(req("DELETE", `/v1/devices/${data.device_id}`, undefined, bearer("B".repeat(43))))).status).toBe(401);
    expect((await call(req("DELETE", `/v1/devices/${data.device_id}`, undefined, bearer(data.device_secret)))).status).toBe(204);
    expect((await env.DB.prepare("SELECT count(*) c FROM devices").first<any>()).c).toBe(0);
    expect((await call(req("DELETE", `/v1/devices/${data.device_id}`, undefined, bearer(data.device_secret)))).status).toBe(204);
  });
});

it("unknown routes 404 as JSON", async () => {
  const r = await call(req("GET", "/nope"));
  expect(r.status).toBe(404);
  expect(await r.json()).toEqual({ error: "not found" });
});
