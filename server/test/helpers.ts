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
  calls: { path: string; token: string }[];
}

export function untappdMock(over: Partial<UntappdMock> = {}): UntappdMock {
  return { uid: 42, authOk: true, status: 200, counts: {}, unified: 0, items: [], calls: [], ...over };
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
  if (url.pathname === "/v4/notifications") return Response.json({ ...envelope, response: { notifications: { items: u.items } } });
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

export const toastItem = (checkin: number, at: string, first = "Jamie", last = "Smith") => ({
  checkin_id: checkin,
  created_at: at,
  notification_type: "toast",
  count: 1,
  users: [{ user: { first_name: first, last_name: last, user_name: "x" } }],
  beer: { beer_name: "Late Nights III" },
});

export function req(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  return new Request("https://t.example" + path, {
    method,
    headers: { "content-type": "application/json", "cf-connecting-ip": "1.2.3.4", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
