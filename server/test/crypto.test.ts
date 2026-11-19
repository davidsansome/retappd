import { describe, expect, it } from "vitest";
import { decryptToken, encryptToken, hashSecret, newDeviceSecret, rewrapBatch, rewrapDek, timingSafeEqual, verifySecret } from "../src/crypto";
import { K1, K2, resetDb, testEnv } from "./helpers";

describe("envelope crypto", () => {
  it("round-trips", async () => {
    const env = testEnv();
    const s = await encryptToken(env, "dev-1", "secret-token-123");
    expect(s.key_version).toBe(1);
    expect(s.token_enc).not.toContain("secret-token");
    expect(await decryptToken(env, { id: "dev-1", ...s })).toBe("secret-token-123");
  });

  it("uses fresh DEK and IV each time", async () => {
    const env = testEnv();
    const a = await encryptToken(env, "d", "same-token-value");
    const b = await encryptToken(env, "d", "same-token-value");
    expect(a.token_enc).not.toBe(b.token_enc);
    expect(a.dek_enc).not.toBe(b.dek_enc);
  });

  it("rejects ciphertext moved to another row (AAD)", async () => {
    const env = testEnv();
    const s = await encryptToken(env, "dev-1", "secret-token-123");
    await expect(decryptToken(env, { id: "dev-2", ...s })).rejects.toThrow("decryption failed");
  });

  it("rejects swapping the token ciphertext between rows", async () => {
    const env = testEnv();
    const a = await encryptToken(env, "A", "token-aaaaaaaa");
    const b = await encryptToken(env, "B", "token-bbbbbbbb");
    await expect(decryptToken(env, { id: "A", token_enc: b.token_enc, dek_enc: a.dek_enc, key_version: 1 })).rejects.toThrow();
  });

  it("rejects tampered ciphertext and a lying key_version", async () => {
    const env = testEnv({ MASTER_KEY_V2: K2 });
    const s = await encryptToken(env, "d", "token-xxxxxxxx");
    const bytes = atob(s.token_enc).split("");
    bytes[20] = String.fromCharCode(bytes[20].charCodeAt(0) ^ 1);
    await expect(decryptToken(env, { id: "d", ...s, token_enc: btoa(bytes.join("")) })).rejects.toThrow("decryption failed");
    await expect(decryptToken(env, { id: "d", ...s, key_version: 2 })).rejects.toThrow();
  });

  it("errors do not contain the token or key", async () => {
    const env = testEnv();
    const s = await encryptToken(env, "d", "token-xxxxxxxx");
    try {
      await decryptToken(env, { id: "other", ...s });
    } catch (e: any) {
      expect(String(e.message)).not.toContain("token-xxxxxxxx");
      expect(String(e.message)).not.toContain(K1);
    }
  });

  it("rejects bad master key sizes", async () => {
    await expect(encryptToken(testEnv({ MASTER_KEY_V1: btoa("short") }), "d", "t-t-t-t-t")).rejects.toThrow("32 bytes");
    await expect(encryptToken(testEnv({ MASTER_KEY_CURRENT: "3" }), "d", "t-t-t-t-t")).rejects.toThrow("not configured");
  });
});

describe("rotation", () => {
  it("rewraps the DEK under the new key, old and new versions coexist", async () => {
    const v1 = testEnv();
    const s = await encryptToken(v1, "d", "token-rotate-me");
    const both = testEnv({ MASTER_KEY_V2: K2, MASTER_KEY_CURRENT: "2" });
    // old row still readable while both keys exist
    expect(await decryptToken(both, { id: "d", ...s })).toBe("token-rotate-me");
    const w = await rewrapDek(both, { id: "d", ...s });
    expect(w.key_version).toBe(2);
    expect(w.dek_enc).not.toBe(s.dek_enc);
    // after dropping V1 only the rewrapped row works
    const only2 = testEnv({ MASTER_KEY_V1: undefined, MASTER_KEY_V2: K2, MASTER_KEY_CURRENT: "2" });
    expect(await decryptToken(only2, { id: "d", token_enc: s.token_enc, ...w })).toBe("token-rotate-me");
    await expect(decryptToken(only2, { id: "d", ...s })).rejects.toThrow();
  });

  it("rewrapBatch migrates stored rows", async () => {
    const v1 = testEnv();
    await resetDb(v1);
    await v1.DB.prepare("INSERT INTO users (uid, created_at) VALUES (1, 0)").run();
    const s = await encryptToken(v1, "d1", "token-in-db-1");
    await v1.DB.prepare(
      "INSERT INTO devices (id, uid, secret_hash, apns_token, apns_env, prefs, token_enc, dek_enc, key_version, created_at, last_seen_at) VALUES ('d1',1,'h','t','sandbox','{}',?,?,?,0,0)",
    ).bind(s.token_enc, s.dek_enc, s.key_version).run();
    const v2 = testEnv({ MASTER_KEY_V2: K2, MASTER_KEY_CURRENT: "2" });
    expect(await rewrapBatch(v2)).toEqual({ rewrapped: 1, failed: 0 });
    const row = await v2.DB.prepare("SELECT * FROM devices WHERE id='d1'").first<any>();
    expect(row.key_version).toBe(2);
    expect(await decryptToken(testEnv({ MASTER_KEY_V1: undefined, MASTER_KEY_V2: K2, MASTER_KEY_CURRENT: "2" }), row)).toBe("token-in-db-1");
    expect(await rewrapBatch(v2)).toEqual({ rewrapped: 0, failed: 0 });
  });
});

describe("device secrets", () => {
  it("are 32 random bytes, hashed, compared in constant time", async () => {
    const s = newDeviceSecret();
    expect(s).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newDeviceSecret()).not.toBe(s);
    const h = await hashSecret(s);
    expect(h).not.toContain(s);
    expect(await verifySecret(s, h)).toBe(true);
    expect(await verifySecret(s + "x", h)).toBe(false);
    expect(timingSafeEqual("abc", "abd")).toBe(false);
    expect(timingSafeEqual("abc", "abcd")).toBe(false);
    expect(timingSafeEqual("abc", "abc")).toBe(true);
  });
});
