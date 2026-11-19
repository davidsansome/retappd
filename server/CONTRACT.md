# Retappd notification relay: app <-> server contract (v1)

Base URL: configurable in the app (Info.plist key `RetappdNotifyBaseURL`, set via an
`INFOPLIST_KEY_`-style setting in project.yml). Placeholder until deploy:
`https://retappd-notify.example.workers.dev`. All bodies are JSON, UTF-8.

## Register a device
POST /v1/devices
{
  "untappd_token": "<the user's Untappd access token>",
  "apns_token": "<hex APNs device token>",
  "apns_env": "production" | "sandbox",      // Debug builds: sandbox; TestFlight/App Store: production
  "prefs": { "toast": true, "comment": true, "tag": true, "friend": true },
  "app_version": "1.2 (34)"
}
200 { "device_id": "<uuid>", "device_secret": "<base64url, 32 random bytes>" }
400 bad body; 401 Untappd rejected the token; 429 rate limited.
The server verifies the token with Untappd and binds the device to that Untappd uid.
The app stores device_id + device_secret in the Keychain.

## Update / heartbeat
PATCH /v1/devices/{device_id}
Authorization: Bearer <device_secret>
Body: any subset of untappd_token, apns_token, apns_env, prefs, app_version. `{}` = heartbeat.
Every successful PATCH refreshes last_seen. 200 { "ok": true }.
401 wrong secret; 404 unknown/deleted device -> the app registers again (POST).
If untappd_token changes, the server re-verifies it; if it belongs to a different uid, 401
(the app should DELETE and POST instead, e.g. after an account switch).
The app sends a heartbeat when it comes to the foreground, at most once every 12 hours, and a
PATCH whenever the APNs token, Untappd token or prefs change.

## Delete
DELETE /v1/devices/{device_id}
Authorization: Bearer <device_secret>
204 (also 204/404 if already gone; the app treats both as success).
The app calls this on sign-out BEFORE clearing its local token. If it fails (offline), it keeps
the device_id+secret in a "pending deletion" Keychain item and retries on next launch / when
online, then forgets them.

## Server-side deletion (the app just re-registers on 404)
- Untappd returns an auth error for the token.
- APNs says the device token is no longer valid (410 / BadDeviceToken / Unregistered).
- No PATCH/POST from the app for 30 days.

## Push payload
{
  "aps": {
    "alert": { "body": "Jamie S toasted your Late Nights III" },
    "badge": 3,                     // Untappd unified_count
    "sound": "default",
    "thread-id": "checkin-1582931702"
  },
  "retappd": {
    "type": "toast" | "comment" | "tag" | "comment_tag" | "friend_request",
    "checkin_id": 1582931702,       // absent for friend_request
    "actor": "Jamie S"
  }
}
Tapping: checkin types open that check-in (fetch via GET /v4/checkin/view/{id} if needed);
friend_request opens Me > Friends (the Requests section).

## Addendum (server behaviour)
- `friend_request` pushes use `"thread-id": "friends"` and no `checkin_id`.
- When more than 5 pushes are due in one poll, the oldest collapse into one push with body "N more notifications",
  `badge` set, and no `retappd` key (tapping just opens the app).
- Delivering a push marks the user's Untappd notifications read (reading the feed is the only way to see it).
