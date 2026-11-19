-- No notification contents, names or usernames are ever stored.
CREATE TABLE users (
  uid           INTEGER PRIMARY KEY,           -- Untappd user id
  marker        TEXT,                          -- newest-seen marker; NULL = baseline not yet recorded
  last_counts   TEXT,                          -- JSON of last unread counts
  next_poll_at  INTEGER,                       -- ms epoch; NULL = default cadence (only set while backing off)
  fail_count    INTEGER NOT NULL DEFAULT 0,    -- consecutive errors (backoff exponent)
  created_at    INTEGER NOT NULL
);

CREATE TABLE devices (
  id            TEXT PRIMARY KEY,              -- uuid
  uid           INTEGER NOT NULL REFERENCES users(uid),
  secret_hash   TEXT NOT NULL,                 -- base64 SHA-256 of device_secret
  apns_token    TEXT NOT NULL,
  apns_env      TEXT NOT NULL CHECK (apns_env IN ('production','sandbox')),
  prefs         TEXT NOT NULL,                 -- JSON {toast,comment,tag,friend}
  token_enc     TEXT NOT NULL,                 -- base64(iv || AES-GCM(untappd token)) under the row DEK
  dek_enc       TEXT NOT NULL,                 -- base64(iv || AES-GCM(DEK)) under master key `key_version`
  key_version   INTEGER NOT NULL,
  app_version   TEXT,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL
);
CREATE INDEX devices_uid ON devices(uid, last_seen_at);
CREATE INDEX devices_apns ON devices(apns_token);
CREATE INDEX devices_seen ON devices(last_seen_at);

-- Fixed-window per-IP counter for POST /v1/devices (key = hash of IP, not the IP itself).
CREATE TABLE rate_limits (
  key          TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL,
  PRIMARY KEY (key, window_start)
);
