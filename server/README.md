# Retappd notify server

Cloudflare Worker + D1. Untappd only pushes to its official app, so this polls each registered user's Untappd
notifications about once a minute and sends APNs pushes to Retappd. API contract: [CONTRACT.md](CONTRACT.md).
Security design: [SECURITY.md](SECURITY.md).

## Layout
- `src/api.ts` endpoints (POST/PATCH/DELETE `/v1/devices`), validation, per-IP rate limit (D1 counter), device cap
- `src/poll.ts` scheduled poll (every minute) and daily cleanup + key rewrap
- `src/untappd.ts` **all Untappd API knowledge** (uid lookup, count poll, notification fetch, new-item detection,
  message formatting). Entries marked `GUESS` await the measurement findings.
- `src/apns.ts` `ApnsSender` interface + `FetchApnsSender` (ES256 JWT, 50 min cache)
- `src/crypto.ts` envelope encryption, rewrap, device secrets
- `migrations/` D1 schema

## Local dev
```
cd server && npm install --legacy-peer-deps   # (npm 10 hits an arborist bug without the flag)
npx wrangler d1 migrations apply retappd-notify --local
npm run dev                                    # wrangler dev --local --test-scheduled
curl "http://localhost:8787/cdn-cgi/handler/scheduled?cron=*+*+*+*+*"   # trigger a poll
```
Secrets go in `.dev.vars` (gitignored). `wrangler dev` runs workerd, which has no HTTP/2 client, so real APNs calls
fail locally (see below); tests mock `fetch`.

## Tests
`npm test` (vitest + `@cloudflare/vitest-plugin`, the renamed `@cloudflare/vitest-pool-workers`), `npm run typecheck`.

## APNs and HTTP/2
APNs requires HTTP/2. Cloudflare's docs don't state which HTTP version Worker `fetch()` uses. Per a workerd
maintainer in [workerd#4841](https://github.com/cloudflare/workerd/issues/4841), workerd has no HTTP/2 support, but in
production Cloudflare's proxy stack upgrades subrequests to HTTP/2, so APNs via plain `fetch` works when deployed
and fails under local `wrangler dev`. Community libraries (e.g. `@fivesheepco/cloudflare-apns2`) do the same.
Unverified until the first real push: **test a push right after first deploy.** If it fails, implement another
`ApnsSender` (e.g. a tiny Node/Fly/Deno relay that accepts the payload and speaks HTTP/2).

## Deployment (later)
1. `npx wrangler login`, then `npx wrangler d1 create retappd-notify`; paste the id into `wrangler.jsonc`.
2. `npx wrangler d1 migrations apply retappd-notify --remote`
3. `openssl rand -base64 32 | npx wrangler secret put MASTER_KEY_V1`
4. `npx wrangler secret put APNS_KEY_P8 < AuthKey_898X3U57H6.p8` (APNs key id/team id are plain vars in wrangler.jsonc)
5. `npx wrangler deploy`; put the workers.dev URL in the app's `RetappdNotifyBaseURL`.
Behind the Cloudflare edge, rate limiting uses `cf-connecting-ip`.

## Cost notes
Needs Workers Paid ($5/mo): a per-minute cron plus a subrequest per user per poll exceeds the free plan (50
subrequests/invocation). D1 writes are the metered item, so polls write nothing unless state changes: no
"last_polled" column; stale-user (7d) 5-minute cadence is derived statelessly from `minute % 5 == uid % 5`;
`next_poll_at`/`fail_count` are written only when backing off and cleared once on recovery; counts/marker are written
only when they change. Queues are avoided: a bounded in-process pool (25 parallel) is enough at this scale and
Queues would add per-message operations and cost. Over 500 due users, polls are sharded across minutes.

## Known limits
A user who reads one notification and gets another between two polls leaves counts unchanged and is missed.
Heartbeat PATCH writes `last_seen_at` (one write per device per 12h at most).
