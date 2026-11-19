import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleRequest, ipPrefix } from "../src/api";
import { clearJwtCache, invalidateJwt, providerJwt } from "../src/apns";
import { encryptToken, rewrapBatch } from "../src/crypto";
import { intVar } from "../src/env";
import { cleanRateLimits, runPoll } from "../src/poll";
import { formatMessage } from "../src/untappd";
import { FakeApns, K2, item, mockFetch, req, resetDb, testEnv, untappdMock } from "./helpers";

const env = testEnv();
let u = untappdMock();
const T0 = Date.UTC(2026, 10, 19, 12, 0, 0);
const tok = (c: string) => c.repeat(64);

async function register(apns: string, uid = 42, ip = "1.1.1.1", now = T0, e = env) {
  u.uid = uid;
  const r = await handleRequest(req("POST", "/v1/devices", { untappd_token: "good-token-" + uid, apns_token: apns, apns_env: "sandbox" }, { "cf-connecting-ip": ip }), e, now);
  return { res: r, data: r.status === 200 ? ((await r.clone().json()) as any) : null };
}
const rows = async () => (await env.DB.prepare("SELECT id, uid, apns_token FROM devices").all<any>()).results;
const users = async () => (await env.DB.prepare("SELECT uid FROM users").all<any>()).results.map((r) => r.uid);

beforeEach(async () => {
  await resetDb(env);
  u = untappdMock();
  mockFetch(u);
});
afterEach(() => {
  vi.unstubAllGlobals();
  clearJwtCache();
});

describe("apns_token takeover (M1)", () => {
  it("POST by another uid replaces the holder and prunes its emptied user row", async () => {
    await register(tok("a"), 1);
    expect(await users()).toEqual([1]);
    const { res } = await register(tok("a"), 2);
    expect(res.status).toBe(200);
    expect((await rows()).map((r) => r.uid)).toEqual([2]);
    expect(await users()).toEqual([2]);
  });

  it("PATCH apns_token applies the same replace rule", async () => {
    const victim = await register(tok("a"), 1, "1.1.1.1");
    const mine = await register(tok("b"), 2, "2.2.2.2");
    const r = await handleRequest(
      req("PATCH", `/v1/devices/${mine.data.device_id}`, { apns_token: tok("a") }, { authorization: `Bearer ${mine.data.device_secret}` }),
      env,
      T0 + 1000,
    );
    expect(r.status).toBe(200);
    const all = await rows();
    expect(all.map((x) => x.id)).toEqual([mine.data.device_id]);
    expect(all[0].apns_token).toBe(tok("a"));
    expect(victim.data.device_id).not.toBe(mine.data.device_id);
    expect(await users()).toEqual([2]);
  });

  it("limits registrations per APNs token to 3/hour across POST and PATCH", async () => {
    const e = testEnv({ REGISTER_LIMIT_PER_HOUR: "100" });
    // first registration has no holder; the next 3 are cross-uid replacements (counted); the 4th replacement is refused
    for (let i = 0; i < 4; i++) expect((await register(tok("c"), 10 + i, "9.9.9." + i, T0, e)).res.status).toBe(200);
    expect((await register(tok("c"), 20, "9.9.9.9", T0, e)).res.status).toBe(429);
    // PATCH to the throttled token is refused too
    const mine = await register(tok("d"), 30, "8.8.8.8", T0, e);
    const r = await handleRequest(req("PATCH", `/v1/devices/${mine.data.device_id}`, { apns_token: tok("c") }, { authorization: `Bearer ${mine.data.device_secret}` }), e, T0);
    expect(r.status).toBe(429);
    // next hour is fine
    expect((await register(tok("c"), 20, "9.9.9.9", T0 + 3_700_000, e)).res.status).toBe(200);
  });
});

it("same-uid re-registration of a token is never limited", async () => {
  const e = testEnv({ REGISTER_LIMIT_PER_HOUR: "100" });
  for (let i = 0; i < 8; i++) expect((await register(tok("5"), 77, "7.7.7." + i, T0, e)).res.status).toBe(200);
});

describe("decrypt failures (M2)", () => {
  async function setup() {
    const { data } = await register(tok("e"), 42);
    await env.DB.prepare("UPDATE users SET marker = ?, friend_marker = ?").bind(String(T0), String(T0)).run();
    return data.device_id as string;
  }
  it("a missing master key is a config error: the device is kept, no Untappd call is made", async () => {
    await setup();
    u.calls.length = 0;
    await runPoll(testEnv({ MASTER_KEY_V1: undefined }), { apns: new FakeApns(), now: T0 + 60_000 });
    expect(await rows()).toHaveLength(1);
    expect(u.calls).toEqual([]);
  });
  it("a genuine AEAD failure deletes the device and its user row", async () => {
    const id = await setup();
    await env.DB.prepare("INSERT OR IGNORE INTO users (uid, created_at, marker, friend_marker) VALUES (43, 0, '1', '1')").run();
    await env.DB.prepare("UPDATE devices SET uid = 43 WHERE id = ?").bind(id).run(); // uid is bound into the AAD
    await runPoll(env, { apns: new FakeApns(), now: T0 + 60_000 });
    expect(await rows()).toEqual([]);
    expect(await users()).not.toContain(43);
  });
});

describe("rate limit hygiene (L2)", () => {
  it("collapses IPv6 to the /64", () => {
    expect(ipPrefix("1.2.3.4")).toBe("1.2.3.4");
    expect(ipPrefix("2001:db8:1:2:aaaa:bbbb:cccc:dddd")).toBe("2001:db8:1:2");
    expect(ipPrefix("2001:0db8:0:0::1")).toBe("2001:db8:0:0");
    expect(ipPrefix("::1")).toBe("0:0:0:0");
    expect(ipPrefix("::ffff:1.2.3.4")).toBe("1.2.3.4");
    expect(ipPrefix("0:0:0:0:0:ffff:1.2.3.4")).toBe("1.2.3.4");
  });
  it("same /64 shares one bucket and the stored key is not the IP", async () => {
    const e = testEnv({ REGISTER_LIMIT_PER_HOUR: "2" });
    await register(tok("1"), 1, "2001:db8:1:2::1", T0, e);
    await register(tok("2"), 1, "2001:db8:1:2::2", T0, e);
    expect((await register(tok("3"), 1, "2001:db8:1:2::3", T0, e)).res.status).toBe(429);
    const keys = (await env.DB.prepare("SELECT key FROM rate_limits").all<any>()).results.map((r) => r.key).join(" ");
    expect(keys).not.toContain("2001");
  });
  it("validates numeric vars and cleans old windows", async () => {
    expect(intVar("abc", 10)).toBe(10);
    expect(intVar("0", 10)).toBe(10);
    expect(intVar("-3", 10)).toBe(10);
    expect(intVar("25", 10)).toBe(25);
    expect(intVar(undefined, 10)).toBe(10);
    await register(tok("1"), 1);
    await cleanRateLimits(env, T0 + 5 * 3_600_000);
    expect((await env.DB.prepare("SELECT count(*) c FROM rate_limits").first<any>()).c).toBe(0);
  });
});

describe("misc hardening", () => {
  it("rejects oversized bodies by content-length, and device_secret responses are no-store", async () => {
    const big = await handleRequest(req("POST", "/v1/devices", { x: 1 }, { "content-length": "100000" }), env, T0);
    expect(big.status).toBe(400);
    const { res } = await register(tok("f"), 5);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("DELETE removes the user row with the last device", async () => {
    const { data } = await register(tok("f"), 5);
    await handleRequest(req("DELETE", `/v1/devices/${data.device_id}`, undefined, { authorization: `Bearer ${data.device_secret}` }), env, T0);
    expect(await users()).toEqual([]);
  });

  it("truncates long names so alert bodies stay short", () => {
    const m = formatMessage(item("toast", 1, T0, "A".repeat(200), "B", "Z".repeat(500)))!;
    expect(m.body.length).toBeLessThan(180);
    expect(m.actor.length).toBeLessThanOrEqual(40);
  });

  it("rewrapBatch deletes genuinely unreadable rows, skips config failures, and doesn't starve", async () => {
    const v1 = testEnv();
    await v1.DB.prepare("INSERT INTO users (uid, created_at) VALUES (1, 0)").run();
    const ins = async (id: string, uid: number, version: number, enc: any) =>
      v1.DB.prepare("INSERT INTO devices (id, uid, secret_hash, apns_token, apns_env, prefs, token_enc, dek_enc, key_version, created_at, last_seen_at) VALUES (?,?,'h',?,'sandbox','{}',?,?,?,0,0)")
        .bind(id, uid, id, enc.token_enc, enc.dek_enc, version).run();
    await ins("good", 1, 1, await encryptToken(v1, "good", 1, "token-good-aaa"));
    await ins("tampered", 1, 1, await encryptToken(v1, "OTHER", 1, "token-bad-aaaa")); // wrong AAD
    await ins("v9", 1, 9, await encryptToken(v1, "v9", 1, "token-v9-aaaaa")); // key v9 not configured
    const v2 = testEnv({ MASTER_KEY_V2: K2, MASTER_KEY_CURRENT: "2" });
    const r = await rewrapBatch(v2);
    expect(r).toEqual({ rewrapped: 1, failed: 1, deleted: 1 });
    expect((await rows()).map((x) => x.id).sort()).toEqual(["good", "v9"]);
  });
});

describe("APNs hardening (L4, L6)", () => {
  async function pem() {
    const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"])) as CryptoKeyPair;
    const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
    return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  }
  it("cache follows the key material and regeneration is limited to once a minute", async () => {
    const e1 = testEnv({ APNS_KEY_P8: await pem() });
    const e2 = testEnv({ APNS_KEY_P8: await pem() });
    const j1 = await providerJwt(e1, 1000);
    expect(await providerJwt(e2, 2000)).not.toBe(j1); // different key, same ids
    const j2 = await providerJwt(e2, 5000);
    invalidateJwt(5000 + 30_000); // too soon after generation: keep
    expect(await providerJwt(e2, 5000 + 30_000)).toBe(j2);
    invalidateJwt(2000 + 61_000);
    expect(await providerJwt(e2, 2000 + 61_000)).not.toBe(j2);
  });
  it("Untappd calls carry a timeout signal", async () => {
    const seen: any[] = [];
    vi.stubGlobal("fetch", async (_u: any, init: any) => {
      seen.push(init?.signal);
      return Response.json({ response: { user: { uid: 1 } } });
    });
    const { fetchUid } = await import("../src/untappd");
    await fetchUid("good-token-xx");
    expect(seen[0]).toBeInstanceOf(AbortSignal);
  });
});
