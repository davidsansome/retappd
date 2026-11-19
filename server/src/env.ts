export interface Env {
  DB: D1Database;
  // Secrets
  MASTER_KEY_V1?: string;
  MASTER_KEY_CURRENT?: string; // plain var: which MASTER_KEY_V<n> encrypts new rows
  APNS_KEY_P8?: string;
  // Plain vars
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
  MAX_DEVICES_PER_UID?: string;
  REGISTER_LIMIT_PER_HOUR?: string;
  POLL_SHARDS?: string; // spread users over N minutes; raise when >500 users are due per minute
  // MASTER_KEY_V2, V3... are read dynamically by crypto.ts
  [k: string]: unknown;
}

export type Prefs = { toast: boolean; comment: boolean; tag: boolean; friend: boolean };
export type NotifType = "toast" | "comment" | "tag" | "comment_tag" | "friend_request";

export interface DeviceRow {
  id: string;
  uid: number;
  secret_hash: string;
  apns_token: string;
  apns_env: "production" | "sandbox";
  prefs: string;
  token_enc: string;
  dek_enc: string;
  key_version: number;
  app_version: string | null;
  created_at: number;
  last_seen_at: number;
}
