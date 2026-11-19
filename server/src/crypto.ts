// Envelope encryption, WebCrypto only.
//   token  --AES-256-GCM(DEK, AAD = deviceId|"token|v1")-->  token_enc
//   DEK    --AES-256-GCM(master[key_version], AAD = deviceId|"dek|v<key_version>")--> dek_enc
// The token AAD has no key version, so rotation only re-wraps the DEK (the token ciphertext stays).
import type { Env } from "./env";

const enc = new TextEncoder();
const dec = new TextDecoder();

export class CryptoError extends Error {
  constructor(msg: string) {
    super(msg); // messages are static strings, never include data
    this.name = "CryptoError";
  }
}

export function b64encode(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
export function b64decode(s: string): Uint8Array {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function b64url(buf: Uint8Array): string {
  return b64encode(buf).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const masterCache = new Map<string, CryptoKey>();

export function currentKeyVersion(env: Env): number {
  const v = parseInt(String(env.MASTER_KEY_CURRENT ?? "1"), 10);
  if (!Number.isInteger(v) || v < 1) throw new CryptoError("bad MASTER_KEY_CURRENT");
  return v;
}

async function masterKey(env: Env, version: number): Promise<CryptoKey> {
  const raw = env[`MASTER_KEY_V${version}`];
  if (typeof raw !== "string" || !raw) throw new CryptoError(`master key v${version} not configured`);
  const cacheKey = `${version}:${raw}`; // in-memory only
  const hit = masterCache.get(cacheKey);
  if (hit) return hit;
  let bytes: Uint8Array;
  try {
    bytes = b64decode(raw.trim());
  } catch {
    throw new CryptoError(`master key v${version} is not base64`);
  }
  if (bytes.length !== 32) throw new CryptoError(`master key v${version} must be 32 bytes`);
  const key = await crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
  masterCache.set(cacheKey, key);
  return key;
}

async function seal(key: CryptoKey, plaintext: Uint8Array, aad: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: enc.encode(aad) }, key, plaintext),
  );
  const out = new Uint8Array(12 + ct.length);
  out.set(iv);
  out.set(ct, 12);
  return b64encode(out);
}

async function open(key: CryptoKey, sealed: string, aad: string): Promise<Uint8Array> {
  try {
    const all = b64decode(sealed);
    return new Uint8Array(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: all.slice(0, 12), additionalData: enc.encode(aad) },
        key,
        all.slice(12),
      ),
    );
  } catch {
    throw new CryptoError("decryption failed"); // deliberately generic
  }
}

const tokenAad = (deviceId: string) => `${deviceId}|token|v1`;
const dekAad = (deviceId: string, version: number) => `${deviceId}|dek|v${version}`;

export interface Sealed {
  token_enc: string;
  dek_enc: string;
  key_version: number;
}

export async function encryptToken(env: Env, deviceId: string, token: string): Promise<Sealed> {
  const version = currentKeyVersion(env);
  const master = await masterKey(env, version);
  const dekBytes = crypto.getRandomValues(new Uint8Array(32));
  const dek = await crypto.subtle.importKey("raw", dekBytes, "AES-GCM", false, ["encrypt"]);
  const token_enc = await seal(dek, enc.encode(token), tokenAad(deviceId));
  const dek_enc = await seal(master, dekBytes, dekAad(deviceId, version));
  dekBytes.fill(0);
  return { token_enc, dek_enc, key_version: version };
}

export async function decryptToken(
  env: Env,
  row: { id: string; token_enc: string; dek_enc: string; key_version: number },
): Promise<string> {
  const master = await masterKey(env, row.key_version);
  const dekBytes = await open(master, row.dek_enc, dekAad(row.id, row.key_version));
  const dek = await crypto.subtle.importKey("raw", dekBytes, "AES-GCM", false, ["decrypt"]);
  dekBytes.fill(0);
  return dec.decode(await open(dek, row.token_enc, tokenAad(row.id)));
}

/** Re-wrap the row's DEK under the current master key. Token ciphertext is untouched. */
export async function rewrapDek(
  env: Env,
  row: { id: string; dek_enc: string; key_version: number },
): Promise<{ dek_enc: string; key_version: number }> {
  const to = currentKeyVersion(env);
  const oldKey = await masterKey(env, row.key_version);
  const dekBytes = await open(oldKey, row.dek_enc, dekAad(row.id, row.key_version));
  const newKey = await masterKey(env, to);
  const dek_enc = await seal(newKey, dekBytes, dekAad(row.id, to));
  dekBytes.fill(0);
  return { dek_enc, key_version: to };
}

/** Rewrap up to `limit` rows not on the current key version. Returns rows rewrapped / failed. */
export async function rewrapBatch(env: Env, limit = 500): Promise<{ rewrapped: number; failed: number }> {
  const cur = currentKeyVersion(env);
  const { results } = await env.DB.prepare(
    "SELECT id, dek_enc, key_version FROM devices WHERE key_version != ? LIMIT ?",
  )
    .bind(cur, limit)
    .all<{ id: string; dek_enc: string; key_version: number }>();
  let rewrapped = 0;
  let failed = 0;
  for (const row of results) {
    try {
      const n = await rewrapDek(env, row);
      // Guard on old values so a concurrent PATCH (which re-encrypts) is not clobbered.
      await env.DB.prepare("UPDATE devices SET dek_enc = ?, key_version = ? WHERE id = ? AND key_version = ? AND dek_enc = ?")
        .bind(n.dek_enc, n.key_version, row.id, row.key_version, row.dek_enc)
        .run();
      rewrapped++;
    } catch {
      failed++;
    }
  }
  return { rewrapped, failed };
}

// ---- device secrets ----

export function newDeviceSecret(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function hashSecret(secret: string): Promise<string> {
  return b64encode(await crypto.subtle.digest("SHA-256", enc.encode(secret)));
}

/** Constant-time compare of two equal-length strings (here: base64 SHA-256 digests). */
export function timingSafeEqual(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function verifySecret(presented: string, storedHash: string): Promise<boolean> {
  return timingSafeEqual(await hashSecret(presented), storedHash);
}
