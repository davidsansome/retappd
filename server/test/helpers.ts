import { env as base } from "cloudflare:workers";
import { vi } from "vitest";
import type { Env } from "../src/env";
import { b64encode } from "../src/crypto";
import type { ApnsSender, SendResult } from "../src/apns";

export const K1 = b64encode(new Uint8Array(32).fill(1));
export const K2 = b64encode(new Uint8Array(32).fill(2));
export const APNS_TOKEN = "ab".repeat(32);

export function testEnv(extra: Record<string, unknown> = {}): Env {
  return { ...(base as any), MASTER_KEY_V1: K1, MASTER_KEY_CURRENT: "1", ...extra } as Env;
}

export async function resetDb(env: Env) {
  await env.DB.batch(["devices", "users", "rate_limits"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
}

export interface UntappdMock {
  uid: number;
  authOk: boolean;
  status: number; // non-auth failure status when != 200
  retryAfter?: string;
  counts: Record<string, number>;
  unified: number;
  items: any[];
  pending: any[];
  zeroOnFetch?: boolean; // the user read everything in another app between the pending poll and the list fetch
  calls: { path: string; token: string }[];
}

export function untappdMock(over: Partial<UntappdMock> = {}): UntappdMock {
  return { uid: 42, authOk: true, status: 200, counts: {}, unified: 0, items: [], pending: [], calls: [], ...over };
}

export function mockFetch(u: UntappdMock) {
  const spy = vi.fn();
  vi.stubGlobal("fetch", (input: any, init?: any) => {
    const url = new URL(typeof input === "string" ? input : input.url);
    if (url.host !== "api.untappd.com") throw new Error("unexpected fetch " + url.host);
    const auth = new Headers(init?.headers).get("authorization") ?? "";
    spy(input);
    return Promise.resolve(untappdResponse(u, url, auth));
  });
  return spy;
}

function untappdResponse(u: UntappdMock, url: URL, auth: string): Response {
  u.calls.push({ path: url.pathname, token: auth.replace("Bearer ", "") });
  if (!u.authOk || auth === "Bearer BADTOKEN12") return new Response("{}", { status: 401 });
  if (u.status !== 200)
    return new Response("{}", { status: u.status, headers: u.retryAfter ? { "retry-after": u.retryAfter } : {} });
  const envelope = {
    meta: { code: 200 },
    notifications: { unread_count: { toasts: 0, comments: 0, friends: 0, messages: 0, venues: 0, others: 0, news: 0, ...u.counts }, unified_count: u.unified },
  };
  if (url.pathname === "/v4/account/usersettings") return Response.json({ ...envelope, response: { user: { uid: u.uid } } });
  if (url.pathname === "/v4/notifications") {
    // Reading the list clears the counters (but this response still shows the pre-clear values).
    const env2 = u.zeroOnFetch ? { ...envelope, notifications: { ...envelope.notifications, unread_count: {}, unified_count: 0 } } : envelope;
    const res = Response.json({ ...env2, response: { notifications: { items: u.items.slice(Number(url.searchParams.get("offset") ?? 0), Number(url.searchParams.get("offset") ?? 0) + 25) } } });
    for (const k of ["toasts", "comments", "others", "news"]) delete u.counts[k];
    u.unified = u.counts.friends ?? 0;
    return res;
  }
  if (url.pathname === "/v4/user/pending") return Response.json({ ...envelope, response: { count: u.pending.length, items: u.pending } });
  return Response.json({ ...envelope, response: {} });
}

export class FakeApns implements ApnsSender {
  sent: { token: string; env: string; payload: any }[] = [];
  result: SendResult | ((token: string) => SendResult) = "ok";
  async send(d: { apns_token: string; apns_env: "production" | "sandbox" }, payload: object) {
    this.sent.push({ token: d.apns_token, env: d.apns_env, payload });
    return typeof this.result === "function" ? this.result(d.apns_token) : this.result;
  }
}

export const item = (type: string, checkin: number, at: number | string, first = "Jamie", last = "Smith", beer: string | null = "Late Nights III") => {
  const created_at = new Date(at).toUTCString().replace("GMT", "+0000");
  return {
    checkin_id: checkin,
    created_at,
    notification_type: type,
    count: 1,
    users: [{ created_at, user: { first_name: first, last_name: last, user_name: "x" } }],
    meta: beer ? { beer: { beer_name: beer } } : {},
  };
};
export const toastItem = (checkin: number, at: number | string) => item("toast", checkin, at);
export const pendingReq = (at: number, uid = 7, first = "Sam", last = "Jones") => ({
  created_at: new Date(at).toUTCString().replace("GMT", "+0000"),
  user: { uid, user_name: "sj", first_name: first, last_name: last },
});

export function req(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  return new Request("https://t.example" + path, {
    method,
    headers: { "content-type": "application/json", "cf-connecting-ip": "1.2.3.4", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
