-- JSON array of "type:checkin_id" keys already pushed at exactly `marker` (same-second dedupe).
ALTER TABLE users ADD COLUMN marker_keys TEXT;
