# Retappd notify server

Cloudflare Worker + D1. Untappd only pushes to its official app, so this polls each registered user's Untappd
notifications about once a minute and sends APNs pushes to Retappd. API contract: [CONTRACT.md](CONTRACT.md).
Security design: [SECURITY.md](SECURITY.md).

## Layout
- `src/api.ts` endpoints (POST/PATCH/DELETE `/v1/devices`), validation, per-IP rate limit (D1 counter), device cap
- `src/poll.ts` scheduled poll (every minute) and daily cleanup + key rewrap
- `src/untappd.ts` **all Untappd API knowledge** (uid lookup, count poll, notification fetch, new-item detection,
  message formatting), based on the measured behaviour in `untappd-private-api/docs/API.md`.
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
5. Add a Cloudflare WAF rate-limiting rule on `POST /v1/devices` (for example 20 requests per 10 minutes per IP) in
   front of the Worker; the in-app D1 counter (10/hour per IP, /64 for IPv6) is a second layer.
6. `npx wrangler deploy`; put the workers.dev URL in the app's `RetappdNotifyBaseURL`.
Behind the Cloudflare edge, rate limiting uses `cf-connecting-ip`.

## Cost notes
Needs Workers Paid ($5/mo): a per-minute cron plus a subrequest per user per poll exceeds the free plan (50
subrequests/invocation). D1 writes are the metered item, so polls write nothing unless state changes: no
"last_polled" column; stale-user (7d) 5-minute cadence is derived statelessly from `minute % 5 == uid % 5`;
`next_poll_at`/`fail_count` are written only when backing off and cleared once on recovery; counts/marker are written
only when they change. Queues are avoided: a bounded in-process pool (25 parallel) is enough at this scale and
Queues would add per-message operations and cost. Beyond ~500 users per minute, set `POLL_SHARDS` (a plain var) to N: each user is then polled every N minutes on a fixed slot (`uid % N`), so
the schedule never changes under a user (the poller logs `over_capacity` as a reminder).

## How polling works (per uid, once a minute)
1. `GET /v4/user/pending` (about 222 bytes, no side effects): the envelope has the unread counts, the body has pending
   friend requests (they never appear in `/v4/notifications`). Requests newer than the friend watermark are pushed.
2. If `comments + toasts + others` is 0, stop. Idle polls make no Untappd list call and no D1 writes.
3. Otherwise fetch `GET /v4/notifications` (first page). K = comments + toasts + others from that call's own
   (pre-clear) envelope; each unread unit is at most one item event. Unhandled items are those with `created_at`
   after the marker, or equal to it with a `(type, checkin_id)` key not already pushed at that exact time (the marker
   row stores those keys). The newest K unhandled items are pushed, oldest first; all unhandled items are then marked
   handled (the older ones were read in another app). No correctness depends on poll timing, so skipped cron runs,
   backoff, stale-user cadence and sharding can't lose items. A re-toast can raise the counter without a list item
   (K too big), so items older than 24 h are never pushed. One push per new item, however many, oldest first
   (sequential per device). If K exceeds the new items found on a full first page, further pages (`offset`) are read
   until K is covered or items older than the marker are reached, capped at 100 items per poll (`item_cap_hit` is logged).
   Badge = the pre-clear `unified_count`.
4. The first poll after registration only records the watermarks (and does not read the list).
Items are keyed by (type, checkin); activity on an existing item moves its `created_at` forward and so pushes again.
A re-toast can raise the counter without a list item: nothing is pushed.

**The relay clears the user's Untappd unread badge.** Reading `/v4/notifications` marks notifications read for the
whole account (the official app too), and there is no non-clearing read. So whenever the relay delivers, the unread
count in the official Untappd app resets, and the first poll after registration clears any backlog that was unread.
Friend requests are not cleared (the count is the number of pending requests).

## Known limits
While paging, an item that moves to the top of the list (new activity) between page fetches can shift the later pages
by one, so a single other item may be skipped. Rare; accepted.
Unit accounting: K is spent newest-first by each item's new `users[]` entries; a user acting twice on one item is two
units but one entry, so older unhandled items inside a window of 2 poll periods + 2 minutes can still be pushed in that case.
A baseline is recorded at registration (and by the first poll if that call failed): marker = now - 60 s.
Each minute the poller starts at a different device of the user (rotation), so a user with several devices uses all of
their Untappd tokens over time and dead ones are found and deleted.
Set `MASTER_KEY_CURRENT` (required) whenever you add a `MASTER_KEY_V<n>`.
If the notification fetch fails after Untappd already cleared the counts (e.g. the response is lost), those items are
never pushed; the counts are gone and the list is only read when something is unread. Rare, accepted.
Heartbeat PATCH writes `last_seen_at` (one write per device per 12h at most). Push failures other than 410 are logged and
not retried (the watermark has advanced). `checkinTag` and `commentTag` have never been produced by Untappd; they are
mapped to `tag` and `comment_tag` best-effort. Migrations: `0002` replaces stored counts with a friend watermark.
