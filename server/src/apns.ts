// APNs sender behind an interface. Requires HTTP/2 to Apple: see README "APNs and HTTP/2".
import type { Env } from "./env";
import { b64url } from "./crypto";
import { log, safeErr } from "./log";

export type SendResult = "ok" | "unregistered" | "error";

export interface ApnsSender {
  send(device: { apns_token: string; apns_env: "production" | "sandbox" }, payload: object): Promise<SendResult>;
}

const enc = new TextEncoder();
let jwtCache: { id: string; jwt: string; at: number } | null = null;
let jwtInFlight: { id: string; promise: Promise<string> } | null = null;
const JWT_TTL_MS = 50 * 60 * 1000; // Apple: refresh no more often than every 20 min, and before 60
const MIN_REGEN_MS = 60_000; // never regenerate more than once a minute (e.g. after InvalidProviderToken)

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

export async function providerJwt(env: Env, now = Date.now()): Promise<string> {
  if (!env.APNS_KEY_P8) throw new Error("APNS_KEY_P8 not configured");
  // Cache id covers the key material too, so a rotated .p8 is picked up.
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(env.APNS_KEY_P8)));
  const id = `${env.APNS_KEY_ID}:${env.APNS_TEAM_ID}:${b64url(digest.slice(0, 8))}`;
  if (jwtCache && jwtCache.id === id && now - jwtCache.at < JWT_TTL_MS) return jwtCache.jwt;
  if (jwtInFlight && jwtInFlight.id === id) return jwtInFlight.promise;
  const promise = (async () => {
    let key: CryptoKey;
    try {
      key = await crypto.subtle.importKey("pkcs8", pemToDer(env.APNS_KEY_P8!), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    } catch (e) {
      log("apns_key_import_failed", { error: safeErr(e) });
      throw e;
    }
    const head = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
    const claims = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })));
    const input = `${head}.${claims}`;
    // WebCrypto ECDSA output is raw r||s, exactly the JWS ES256 signature format.
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(input)));
    const jwt = `${input}.${b64url(sig)}`;
    jwtCache = { id, jwt, at: now };
    return jwt;
  })();
  jwtInFlight = { id, promise };
  try {
    return await promise;
  } finally {
    if (jwtInFlight?.promise === promise) jwtInFlight = null;
  }
}

/** Drop the cached JWT, but no more than once a minute (a bad key must not cause a signing storm). */
export function invalidateJwt(now = Date.now()) {
  if (jwtCache && now - jwtCache.at >= MIN_REGEN_MS) jwtCache = null;
}

export function clearJwtCache() {
  jwtCache = null;
  jwtInFlight = null;
}

const DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered"]);

export class FetchApnsSender implements ApnsSender {
  constructor(private env: Env) {}
  async send(device: { apns_token: string; apns_env: "production" | "sandbox" }, payload: object): Promise<SendResult> {
    let jwt: string;
    try {
      jwt = await providerJwt(this.env);
    } catch (e) {
      log("apns_jwt_failed", { error: safeErr(e) });
      return "error";
    }
    const host = device.apns_env === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    let res: Response;
    try {
      res = await fetch(`https://${host}/3/device/${device.apns_token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": this.env.APNS_TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10_000),
      });
    } catch (e) {
      log("apns_fetch_failed", { error: safeErr(e) });
      return "error";
    }
    if (res.status === 200) return "ok";
    let reason = "";
    try {
      reason = ((await res.json()) as any)?.reason ?? "";
    } catch {}
    log("apns_non_200", { status: res.status, reason });
    if (res.status === 410 || DEAD_REASONS.has(reason)) return "unregistered";
    if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") invalidateJwt();
    return "error";
  }
}
