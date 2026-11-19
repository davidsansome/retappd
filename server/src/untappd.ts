// Everything that knows Untappd's API shape lives here (see docs/API.md in untappd-private-api).
import type { NotifType } from "./env";

const BASE = "https://api.untappd.com";
// Static app credentials baked into the official Android APK (docs/API.md, "Authentication").
const CLIENT_ID = "20B24F8EF10B1A76BBF23B39528B7AB770FFB264";
const CLIENT_SECRET = "10E493969C8A985966F106DC1542E85230B53A26";

export class UntappdAuthError extends Error {
  constructor() {
    super("untappd auth rejected");
    this.name = "UntappdAuthError";
  }
}
export class UntappdError extends Error {
  constructor(
    public status: number,
    public retryAfterSec?: number,
  ) {
    super(`untappd error ${status}`);
    this.name = "UntappdError";
  }
}

export interface Counts {
  toasts: number;
  comments: number;
  friends: number;
  messages: number;
  venues: number;
  others: number;
  news: number;
  unified: number;
}

export interface FriendRequest {
  at: number; // ms epoch
  uid: number;
  actor: string;
}

async function call(token: string, path: string, params: Record<string, string> = {}) {
  const qs = new URLSearchParams({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, utv: "4.0.0", ...params });
  const res = await fetch(`${BASE}${path}?${qs}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      "User-Agent": "Untappd/4.7.13 (android; Android 14)",
      "X-Untappd-App-Version": "4.7.13",
      "X-Untappd-App": "android",
      Accept: "application/json; charset=utf-8",
    },
  });
  // Invalid token: HTTP 401, meta.error_type "invalid_token" (its error_detail echoes the token: never log bodies).
  if (res.status === 401) throw new UntappdAuthError();
  if (!res.ok) {
    const ra = Number(res.headers.get("retry-after"));
    // Valid tokens showed x-auth-type: unlimited and no 429 was ever seen; Retry-After is honoured anyway.
    throw new UntappdError(res.status, Number.isFinite(ra) && ra > 0 ? ra : undefined);
  }
  const json = (await res.json()) as any;
  if (json?.meta?.code === 401) throw new UntappdAuthError();
  return json;
}

function parseCounts(json: any): Counts {
  const u = json?.notifications?.unread_count ?? {};
  const n = (k: string) => (typeof u[k] === "number" ? u[k] : 0);
  return {
    toasts: n("toasts"),
    comments: n("comments"),
    friends: n("friends"),
    messages: n("messages"),
    venues: n("venues"),
    others: n("others"),
    news: n("news"),
    unified: typeof json?.notifications?.unified_count === "number" ? json.notifications.unified_count : 0,
  };
}

/** Comments + toasts + others: the counters that GET /v4/notifications clears. Friends are separate. */
export const unreadActivity = (c: Counts) => c.comments + c.toasts + c.others;

/** SWAPPABLE: verifies a token and returns the authenticated user's uid (usersettings: response.user.uid). */
export async function fetchUid(token: string): Promise<number> {
  const json = await call(token, "/v4/account/usersettings");
  const uid = json?.response?.user?.uid;
  if (!Number.isInteger(uid)) throw new UntappdError(502);
  return uid;
}

function displayName(u?: { first_name?: string; last_name?: string; user_name?: string }): string {
  return u?.first_name ? `${u.first_name}${u.last_name ? " " + u.last_name[0] : ""}` : (u?.user_name ?? "Someone");
}

/**
 * Side-effect-free poll (~222 B): GET /v4/user/pending. Its envelope carries the unread counts and its
 * body lists pending friend requests (which never appear in /v4/notifications).
 */
export async function pollCounts(token: string): Promise<{ counts: Counts; requests: FriendRequest[] }> {
  const json = await call(token, "/v4/user/pending");
  const requests: FriendRequest[] = [];
  for (const i of json?.response?.items ?? []) {
    const at = Date.parse(i?.created_at);
    if (Number.isFinite(at) && Number.isInteger(i?.user?.uid)) requests.push({ at, uid: i.user.uid, actor: displayName(i.user) });
  }
  return { counts: parseCounts(json), requests };
}

export interface NotificationItem {
  checkin_id?: number;
  created_at: string;
  notification_type: string; // toast | comment | checkinFriendTag (seen); checkinTag | commentTag | promo (never seen)
  count?: number;
  users?: { created_at?: string; user?: { first_name?: string; last_name?: string; user_name?: string } }[];
  meta?: { beer?: { beer_name?: string } };
}

/**
 * GET /v4/notifications, first page. WARNING: this marks the account's notifications read (clears
 * comments/toasts/others/news and unified_count for the official app too). The returned counts are the
 * envelope of this very call, i.e. the values from before the clear. Only call when something is unread.
 */
export async function fetchNotifications(token: string): Promise<{ items: NotificationItem[]; counts: Counts }> {
  const json = await call(token, "/v4/notifications", {
    version: "2",
    includes: "commentTag,checkinTag,checkinFriendTag,toast,comment,promo",
    is_news: "false",
  });
  return { items: json?.response?.notifications?.items ?? [], counts: parseCounts(json) };
}

export const itemTime = (i: NotificationItem) => Date.parse(i.created_at) || 0;

/**
 * Items are keyed by (notification_type, checkin_id) and item.created_at moves forward on new activity,
 * so "new" = created_at strictly after the threshold. Unknown types (promo) are dropped. Oldest first.
 */
export function newItemsSince(items: NotificationItem[], threshold: number): NotificationItem[] {
  return items
    .filter((i) => itemTime(i) > threshold && classify(i.notification_type) !== null)
    .sort((a, b) => itemTime(a) - itemTime(b));
}

export interface FormattedMessage {
  type: NotifType;
  checkinId?: number;
  actor: string;
  body: string;
}

export function classify(t: string): NotifType | null {
  switch (t) {
    case "toast": return "toast";
    case "comment": return "comment";
    case "checkinFriendTag": // seen: you were tagged by a friend
    case "checkinTag": // never produced; best effort
      return "tag";
    case "commentTag": return "comment_tag"; // never produced; best effort
    default: return null;
  }
}

export function formatMessage(item: NotificationItem): FormattedMessage | null {
  const type = classify(item.notification_type);
  if (!type) return null;
  const actor = displayName(item.users?.[0]?.user);
  const beer = item.meta?.beer?.beer_name;
  const body = {
    toast: `${actor} toasted your ${beer ?? "check-in"}`,
    comment: `${actor} commented on your ${beer ?? "check-in"}`,
    tag: `${actor} tagged you in ${beer ?? "a check-in"}`,
    comment_tag: `${actor} mentioned you on ${beer ?? "a check-in"}`,
    friend_request: `${actor} sent you a friend request`,
  }[type];
  return { type, checkinId: item.checkin_id, actor, body };
}

export function formatFriendRequest(r: FriendRequest): FormattedMessage {
  return { type: "friend_request", actor: r.actor, body: `${r.actor} sent you a friend request` };
}
