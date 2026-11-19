# Security

## What is stored
- Per device: the Untappd access token (encrypted), a SHA-256 of the device secret, the APNs token, prefs.
- Per user: Untappd uid, poll state (two watermark timestamps, backoff). No notification contents, names or usernames.
- Rate-limit rows keyed by a truncated SHA-256 of the client IP (the IP itself is not stored).

## Envelope encryption
Each Untappd token is encrypted with AES-256-GCM under a random per-row data key (DEK). The DEK is wrapped with
AES-256-GCM under a master key held only as a Worker secret (`MASTER_KEY_V<n>`). AAD binds ciphertexts to their row:
token AAD = `deviceId|token|v1`, DEK AAD = `deviceId|dek|v<key_version>`, so rows (or a forged `key_version`) can't be
swapped. IVs are random 96-bit. WebCrypto only. Tokens, secrets and decrypted values are never logged; crypto errors
are static strings; logs are allowlisted (`log.ts`).

device_secret is 32 random bytes, shown once; only its SHA-256 is stored (high entropy, so no slow hash), compared in
constant time.

## Threat model
| Attacker obtains | Exposed | Not exposed |
|---|---|---|
| D1 database dump/leak | APNs tokens, uids, prefs, ciphertexts, secret hashes | Untappd tokens (need master key); device secrets (preimage of SHA-256 of 256 random bits) |
| Source code leak | Nothing secret (Untappd client id/secret are public in the APK; APNs key id/team id are not secret) | Master key, .p8, data |
| Cloudflare account compromise | Everything: secrets are readable by the account owner/deploys, and D1. They can decrypt all tokens and push as Retappd. | Mitigate with 2FA, least-privilege API tokens, audit logs |
| APNs token alone | Cannot push (needs the .p8) | |
A stolen Untappd token gives access to that user's Untappd account, which is why the tokens are encrypted at rest.
Residual: the Worker decrypts tokens at runtime, so a malicious deployment can exfiltrate them.

## Generating the master key (never written to disk)
```
openssl rand -base64 32 | npx wrangler secret put MASTER_KEY_V1
```
`wrangler secret put` reads stdin; the key only exists in the pipe. `MASTER_KEY_CURRENT` (a plain var, default `1`)
selects which version encrypts new rows. Local dev uses a throwaway key in the gitignored `.dev.vars`.

## Rotation
1. `openssl rand -base64 32 | npx wrangler secret put MASTER_KEY_V2`
2. Set `MASTER_KEY_CURRENT` to `"2"` in `wrangler.jsonc`, deploy. New rows use v2; old rows still decrypt via v1.
3. The daily cron (`rewrapBatch`, 500 rows/run) re-wraps every row's DEK under v2 (token ciphertext is untouched).
4. When `SELECT count(*) FROM devices WHERE key_version != 2` is 0, `npx wrangler secret delete MASTER_KEY_V1`.

## Lost master key
Rows can't be decrypted. The poller deletes undecryptable devices; the app gets 404 on its next heartbeat and
re-registers. No data of value is lost.
