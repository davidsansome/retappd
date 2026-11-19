// APNs sender behind an interface. Requires HTTP/2 to Apple: see README "APNs and HTTP/2".
import type { Env } from "./env";
import { b64url } from "./crypto";

export type SendResult = "ok" | "unregistered" | "error";

export interface ApnsSender {
  send(device: { apns_token: string; apns_env: "production" | "sandbox" }, payload: object): Promise<SendResult>;
}

const enc = new TextEncoder();
let jwtCache: { key: string; jwt: string; at: number } | null = null;
const JWT_TTL_MS = 50 * 60 * 1000; // Apple: refresh no more often than every 20 min, and before 60

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

export async function providerJwt(env: Env, now = Date.now()): Promise<string> {
  if (!env.APNS_KEY_P8) throw new Error("APNS_KEY_P8 not configured");
  const id = `${env.APNS_KEY_ID}:${env.APNS_TEAM_ID}`;
  if (jwtCache && jwtCache.key === id && now - jwtCache.at < JWT_TTL_MS) return jwtCache.jwt;
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(env.APNS_KEY_P8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })));
  const input = `${head}.${claims}`;
  // WebCrypto ECDSA output is raw r||s, exactly the JWS ES256 signature format.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(input)));
  const jwt = `${input}.${b64url(sig)}`;
  jwtCache = { key: id, jwt, at: now };
  return jwt;
}

export function clearJwtCache() {
  jwtCache = null;
}

const DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered"]);

export class FetchApnsSender implements ApnsSender {
  constructor(private env: Env) {}
  async send(device: { apns_token: string; apns_env: "production" | "sandbox" }, payload: object): Promise<SendResult> {
    const host = device.apns_env === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    let res: Response;
    try {
      res = await fetch(`https://${host}/3/device/${device.apns_token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${await providerJwt(this.env)}`,
          "apns-topic": this.env.APNS_TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      });
    } catch {
      return "error";
    }
    if (res.status === 200) return "ok";
    let reason = "";
    try {
      reason = ((await res.json()) as any)?.reason ?? "";
    } catch {}
    if (res.status === 410 || DEAD_REASONS.has(reason)) return "unregistered";
    if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") clearJwtCache();
    return "error";
  }
}
