// Everything that knows Untappd's API shape lives here, so findings from the API measurements
// can be applied in one place. GUESSES (from docs/API.md, not yet measured) are marked `GUESS`.
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
  if (res.status === 401 || res.status === 403) throw new UntappdAuthError();
  if (!res.ok) {
    const ra = Number(res.headers.get("retry-after"));
    // GUESS: also honour an X-RateLimit-Reset style header if Untappd sends one.
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

/** SWAPPABLE: verifies a token and returns the authenticated user's uid. */
export async function fetchUid(token: string): Promise<number> {
  // GUESS: usersettings returns the authenticated user object (`user.uid`), per docs/API.md. Heavy
  // but it is the only captured call that identifies the caller without knowing the username.
  const json = await call(token, "/v4/account/usersettings");
  const uid = json?.response?.user?.uid;
  if (!Number.isInteger(uid)) throw new UntappdError(502);
  return uid;
}

/** Cheap unread-counts check. Every response carries the counts in its envelope. */
export async function pollCounts(token: string): Promise<Counts> {
  // GUESS: any authenticated call includes the envelope; use the lightest one. To be measured.
  return parseCounts(await call(token, "/v4/notifications/subscriptions"));
}

export interface NotificationItem {
  checkin_id?: number;
  created_at: string;
  notification_type: string;
  count?: number;
  users?: { user?: { first_name?: string; last_name?: string; user_name?: string } }[];
  beer?: { beer_name?: string }; // GUESS: may not exist; message falls back to generic text
}

export async function fetchNotifications(token: string): Promise<{ items: NotificationItem[]; counts: Counts }> {
  // NOTE: not yet confirmed whether this marks items read (being measured).
  const json = await call(token, "/v4/notifications", {
    version: "2",
    includes: "commentTag,checkinTag,checkinFriendTag,toast,comment,promo",
    is_news: "false",
  });
  return { items: json?.response?.notifications?.items ?? [], counts: parseCounts(json) };
}

const itemTime = (i: NotificationItem) => Date.parse(i.created_at) || 0;

/**
 * GUESS: marker = max created_at (epoch ms, as string) over the feed. Aggregated items (e.g. more
 * toasts on an old check-in) are assumed to get a fresh created_at so they sort as new.
 */
export function newestMarker(items: NotificationItem[]): string {
  return String(items.reduce((m, i) => Math.max(m, itemTime(i)), 0));
}

export function newItemsSince(items: NotificationItem[], marker: string | null) {
  const m = marker === null ? Infinity : Number(marker);
  return {
    items: items.filter((i) => itemTime(i) > m).sort((a, b) => itemTime(a) - itemTime(b)),
    marker: newestMarker(items),
  };
}

export interface FormattedMessage {
  type: NotifType;
  checkinId?: number;
  actor: string;
  body: string;
}

/** GUESS for notification_type strings; unknown types return null (no push). */
export function classify(t: string): NotifType | null {
  const s = t.toLowerCase().replace(/[^a-z]/g, "");
  if (s.includes("commenttag")) return "comment_tag";
  if (s.includes("toast")) return "toast";
  if (s.includes("comment")) return "comment";
  if (s.includes("tag")) return "tag";
  if (s.includes("friend")) return "friend_request";
  return null;
}

export function formatMessage(item: NotificationItem): FormattedMessage | null {
  const type = classify(item.notification_type);
  if (!type) return null;
  const u = item.users?.[0]?.user;
  const actor = u?.first_name ? `${u.first_name}${u.last_name ? " " + u.last_name[0] : ""}` : (u?.user_name ?? "Someone");
  const more = Math.max(0, (item.count ?? item.users?.length ?? 1) - 1);
  const who = more > 0 ? `${actor} and ${more} other${more > 1 ? "s" : ""}` : actor;
  const beer = item.beer?.beer_name;
  const target = beer ? `your ${beer}` : "your check-in";
  const verbs: Record<NotifType, string> = {
    toast: `toasted ${target}`,
    comment: `commented on ${target}`,
    tag: "tagged you in a check-in",
    comment_tag: "mentioned you in a comment",
    friend_request: "sent you a friend request",
  };
  return {
    type,
    checkinId: type === "friend_request" ? undefined : item.checkin_id,
    actor,
    body: `${who} ${verbs[type]}`,
  };
}
