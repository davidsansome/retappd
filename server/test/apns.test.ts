import { afterEach, describe, expect, it, vi } from "vitest";
import { clearJwtCache, FetchApnsSender, providerJwt } from "../src/apns";
import { b64decode } from "../src/crypto";
import { testEnv } from "./helpers";

async function p8(): Promise<{ pem: string; pub: CryptoKey }> {
  const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  return { pem, pub: kp.publicKey };
}
afterEach(() => {
  vi.unstubAllGlobals();
  clearJwtCache();
});

describe("APNs sender", () => {
  it("signs a valid ES256 JWT, caches it, and posts to the right host", async () => {
    const { pem, pub } = await p8();
    const env = testEnv({ APNS_KEY_P8: pem });
    const jwt = await providerJwt(env, 1_000);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(atob(h))).toEqual({ alg: "ES256", kid: "898X3U57H6" });
    expect(JSON.parse(atob(c)).iss).toBe("7B2GP77Y4A");
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, b64decode(s), new TextEncoder().encode(`${h}.${c}`))).toBe(true);
    expect(await providerJwt(env, 1_000 + 49 * 60_000)).toBe(jwt);
    expect(await providerJwt(env, 1_000 + 51 * 60_000)).not.toBe(jwt);

    const f = vi.fn(async () => new Response("", { status: 200 }));
    vi.stubGlobal("fetch", f);
    const sender = new FetchApnsSender(env);
    expect(await sender.send({ apns_token: "ab".repeat(32), apns_env: "sandbox" }, { aps: {} })).toBe("ok");
    expect(await sender.send({ apns_token: "ab".repeat(32), apns_env: "production" }, { aps: {} })).toBe("ok");
    const calls = f.mock.calls as any[];
    expect(calls[0][0]).toBe(`https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
    expect(calls[1][0]).toBe(`https://api.push.apple.com/3/device/${"ab".repeat(32)}`);
    expect(calls[0][1].headers["apns-topic"]).toBe("com.davidsansome.retappd");
  });

  it("maps 410 and BadDeviceToken to unregistered, others to error", async () => {
    const { pem } = await p8();
    const sender = new FetchApnsSender(testEnv({ APNS_KEY_P8: pem }));
    const d = { apns_token: "ab".repeat(32), apns_env: "production" as const };
    const reply = (status: number, reason?: string) => vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ reason }), { status }));
    reply(410, "Unregistered");
    expect(await sender.send(d, {})).toBe("unregistered");
    reply(400, "BadDeviceToken");
    expect(await sender.send(d, {})).toBe("unregistered");
    reply(429, "TooManyRequests");
    expect(await sender.send(d, {})).toBe("error");
    vi.stubGlobal("fetch", async () => { throw new Error("boom"); });
    expect(await sender.send(d, {})).toBe("error");
  });
});
