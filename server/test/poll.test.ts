import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleRequest } from "../src/api";
import { dailyCleanup, dueUsers, runPoll } from "../src/poll";
import { FakeApns, item, mockFetch, pendingReq, req, resetDb, testEnv, toastItem, untappdMock, APNS_TOKEN } from "./helpers";

const env = testEnv();
let u = untappdMock();
let apns = new FakeApns();
const T0 = Date.UTC(2026, 10, 19, 12, 0, 0);

async function register(token = "good-token-1234", apnsToken = APNS_TOKEN, prefs?: object, now = T0, uid = 42) {
  u.uid = uid;
  const r = await handleRequest(req("POST", "/v1/devices", { untappd_token: token, apns_token: apnsToken, apns_env: "sandbox", prefs }, { "cf-connecting-ip": String(Math.random()) }), env, now);
  expect(r.status).toBe(200);
  return ((await r.json()) as any).device_id as string;
}
const poll = (now: number) => runPoll(env, { apns, now });
const user = () => env.DB.prepare("SELECT * FROM users WHERE uid = 42").first<any>();
const devCount = async () => (await env.DB.prepare("SELECT count(*) c FROM devices").first<any>()).c;
const notifCalls = () => u.calls.filter((c) => c.path === "/v4/notifications").length;

beforeEach(async () => {
  await resetDb(env);
  u = untappdMock();
  apns = new FakeApns();
  mockFetch(u);
});
afterEach(() => vi.unstubAllGlobals());

describe("polling", () => {
  const T1 = T0 + 60_000;

  it("first poll records a baseline, pushes nothing and does NOT read the notification list", async () => {
    await register();
    u.items = [toastItem(1, T0 - 5000)];
    u.counts = { toasts: 1 };
    u.unified = 1;
    u.pending = [pendingReq(T0 - 1000)];
    await poll(T1);
    expect(apns.sent).toEqual([]);
    expect(notifCalls()).toBe(0); // reading it would clear the user's unread badge
    const row = await user();
    expect(Number(row.marker)).toBe(T1);
    expect(Number(row.friend_marker)).toBe(T1);
  });

  it("idle polls (nothing unread) fetch nothing and write nothing", async () => {
    await register();
    await poll(T1); // baseline
    const spy = vi.spyOn(env.DB, "prepare");
    await poll(T1 + 60_000);
    await poll(T1 + 120_000);
    expect(notifCalls()).toBe(0);
    expect(spy.mock.calls.filter(([sql]) => /^\s*(UPDATE|INSERT|DELETE)/i.test(sql))).toEqual([]);
    spy.mockRestore();
  });

  it("pushes new activity with the contract payload and the pre-clear unified badge", async () => {
    await register();
    await poll(T1);
    u.items = [toastItem(2, T1 + 70_000)];
    u.counts = { toasts: 1 };
    u.unified = 3;
    await poll(T1 + 120_000);
    expect(apns.sent).toHaveLength(1);
    expect(apns.sent[0].payload).toEqual({
      aps: { alert: { body: "Jamie S toasted your Late Nights III" }, badge: 3, sound: "default", "thread-id": "checkin-2" },
      retappd: { type: "toast", checkin_id: 2, actor: "Jamie S" },
    });
    expect(Number((await user()).marker)).toBe(T1 + 70_000);
    // the fetch cleared the counters, so the next poll is idle: no duplicate
    await poll(T1 + 180_000);
    expect(apns.sent).toHaveLength(1);
    expect(notifCalls()).toBe(1);
  });

  it("formats each type; ignores promo/unknown types", async () => {
    await register();
    await poll(T1);
    const t = T1 + 70_000;
    u.items = [
      item("comment", 3, t + 1000),
      item("checkinFriendTag", 4, t + 2000, "Ann", "Lee"),
      item("commentTag", 5, t + 3000, "Bo", "Ng", null),
      item("promo", 6, t + 4000),
      item("toast", 7, t, "Cy", "Dee", null),
    ];
    u.counts = { comments: 1, toasts: 1, others: 1 };
    await poll(T1 + 120_000);
    expect(apns.sent.map((s) => [s.payload.retappd.type, s.payload.aps.alert.body])).toEqual([
      ["toast", "Cy D toasted your check-in"],
      ["comment", "Jamie S commented on your Late Nights III"],
      ["tag", "Ann L tagged you in Late Nights III"],
      ["comment_tag", "Bo N mentioned you on a check-in"],
    ]);
  });

  it("never pushes activity that was read elsewhere (older than the previous poll) or already handled", async () => {
    await register();
    await poll(T1);
    // item from 10 minutes ago is still in the list but counts are > 0 only because of the new one
    u.items = [toastItem(8, T1 + 100_000), toastItem(9, T1 - 600_000)];
    u.counts = { toasts: 1 };
    await poll(T1 + 120_000);
    expect(apns.sent).toHaveLength(1);
    expect(apns.sent[0].payload.retappd.checkin_id).toBe(8);
    // same list again (watermark must hold even if counts somehow stay up)
    u.counts = { toasts: 1 };
    await poll(T1 + 180_000);
    expect(apns.sent).toHaveLength(1);
  });

  it("an item's re-activity (newer created_at) pushes again", async () => {
    await register();
    await poll(T1);
    u.items = [item("comment", 3, T1 + 70_000)];
    u.counts = { comments: 1 };
    await poll(T1 + 120_000);
    u.items = [item("comment", 3, T1 + 150_000)];
    u.counts = { comments: 1 };
    await poll(T1 + 180_000);
    expect(apns.sent).toHaveLength(2);
  });

  it("a toast counter rise with no list item pushes nothing", async () => {
    await register();
    await poll(T1);
    u.items = [];
    u.counts = { toasts: 1 };
    await poll(T1 + 60_000);
    expect(apns.sent).toEqual([]);
  });

  it("pushes friend requests from /v4/user/pending without reading the list", async () => {
    await register();
    u.pending = [pendingReq(T0 - 1000, 7)];
    await poll(T1); // baseline: existing request not pushed
    u.pending = [pendingReq(T1 + 30_000, 8, "Pat", "Quinn"), pendingReq(T0 - 1000, 7)];
    u.counts = { friends: 2 };
    u.unified = 2;
    await poll(T1 + 60_000);
    expect(notifCalls()).toBe(0);
    expect(apns.sent).toHaveLength(1);
    expect(apns.sent[0].payload).toEqual({
      aps: { alert: { body: "Pat Q sent you a friend request" }, badge: 2, sound: "default", "thread-id": "friends" },
      retappd: { type: "friend_request", actor: "Pat Q" },
    });
    await poll(T1 + 120_000); // watermark advanced: no repeat
    expect(apns.sent).toHaveLength(1);
  });

  it("respects the friend pref", async () => {
    await register("good-token-1234", APNS_TOKEN, { friend: false });
    await poll(T1);
    u.pending = [pendingReq(T1 + 30_000)];
    await poll(T1 + 60_000);
    expect(apns.sent).toEqual([]);
  });

  it("collapses more than 5 pushes into 'N more notifications' and keeps order", async () => {
    await register();
    await poll(T1);
    const t = T1 + 70_000;
    u.items = Array.from({ length: 8 }, (_, i) => toastItem(100 + i, t + i * 1000)).reverse(); // newest first
    u.counts = { toasts: 8 };
    u.unified = 8;
    await poll(T1 + 120_000);
    expect(apns.sent).toHaveLength(5);
    expect(apns.sent[0].payload.aps.alert.body).toBe("4 more notifications");
    expect(apns.sent.slice(1).map((s) => s.payload.retappd.checkin_id)).toEqual([104, 105, 106, 107]);
  });

  it("filters by per-device prefs and pushes to every device of the uid", async () => {
    await register("good-token-1234", "aa".repeat(32), { toast: false });
    await register("good-token-1234", "bb".repeat(32), { toast: true }, T0 + 1);
    await poll(T0 + 60_000);
    u.items = [toastItem(5, T0 + 100_000)];
    u.counts = { toasts: 1 };
    u.calls.length = 0;
    await poll(T0 + 120_000);
    expect(apns.sent.map((s) => s.token)).toEqual(["bb".repeat(32)]);
    // one Untappd poll per uid, not per device
    expect(u.calls.filter((c) => c.path === "/v4/user/pending")).toHaveLength(1);
  });

  it("uses the most recently seen device's token", async () => {
    await register("token-old-device", "aa".repeat(32), undefined, T0);
    await register("token-new-device", "bb".repeat(32), undefined, T0 + 5000);
    u.calls.length = 0;
    await poll(T0 + 60_000);
    expect(u.calls.length).toBeGreaterThan(0);
    expect(u.calls.every((c) => c.token === "token-new-device")).toBe(true);
  });

  it("on Untappd auth error deletes that device and tries the next", async () => {
    await register("good-token-1234", "aa".repeat(32), undefined, T0);
    await register("BADTOKEN12", "bb".repeat(32), undefined, T0 + 5000).catch(() => {});
    // BADTOKEN12 cannot register (401), so insert it directly with a good uid:
    u.authOk = true;
    const id = await (async () => {
      u.uid = 42;
      const r = await handleRequest(req("POST", "/v1/devices", { untappd_token: "willexpire1", apns_token: "cc".repeat(32), apns_env: "sandbox" }, { "cf-connecting-ip": "5.5.5.5" }), env, T0 + 9000);
      return ((await r.json()) as any).device_id as string;
    })();
    // now Untappd starts rejecting the newest device's token only
    const orig = globalThis.fetch;
    vi.stubGlobal("fetch", (i: any, init: any) =>
      new Headers(init?.headers).get("authorization") === "Bearer willexpire1" ? Promise.resolve(new Response("{}", { status: 401 })) : orig(i, init));
    await poll(T0 + 60_000);
    const ids = (await env.DB.prepare("SELECT id FROM devices").all<any>()).results.map((r) => r.id);
    expect(ids).not.toContain(id);
    expect(ids).toHaveLength(1);
    expect((await user()).marker).not.toBeNull(); // baseline recorded via the next device
  });

  it("deletes the user once its last device is rejected", async () => {
    await register();
    u.authOk = false;
    await poll(T0 + 60_000);
    expect(await devCount()).toBe(0);
    expect(await user()).toBeNull();
  });

  it("deletes a device when APNs says 410/Unregistered", async () => {
    await register();
    await poll(T0 + 60_000);
    apns.result = "unregistered";
    u.items = [toastItem(7, T0 + 100_000)];
    u.counts = { toasts: 1 };
    await poll(T0 + 120_000);
    expect(apns.sent).toHaveLength(1);
    expect(await devCount()).toBe(0);
  });

  it("backs off exponentially on errors, honours Retry-After, and resets on success", async () => {
    await register();
    u.status = 500;
    await poll(T0 + 60_000);
    let row = await user();
    expect(row.fail_count).toBe(1);
    expect(row.next_poll_at).toBe(T0 + 60_000 + 60_000);
    // not due yet
    const before = u.calls.length;
    await poll(T0 + 90_000);
    expect(u.calls.length).toBe(before);
    await poll(T0 + 120_000);
    row = await user();
    expect(row.fail_count).toBe(2);
    expect(row.next_poll_at).toBe(T0 + 120_000 + 120_000);
    // 429 with Retry-After larger than the backoff
    u.status = 429;
    u.retryAfter = "900";
    await poll(T0 + 240_000);
    row = await user();
    expect(row.fail_count).toBe(3);
    expect(row.next_poll_at).toBe(T0 + 240_000 + 900_000);
    // recovery
    u.status = 200;
    await poll(T0 + 1_200_000);
    row = await user();
    expect(row.fail_count).toBe(0);
    expect(row.next_poll_at).toBeNull();
  });

  it("caps backoff at one hour", async () => {
    await register();
    await env.DB.prepare("UPDATE users SET fail_count = 20").run();
    u.status = 500;
    await poll(T0 + 60_000);
    expect((await user()).next_poll_at).toBe(T0 + 60_000 + 3_600_000);
  });

  it("polls devices unseen for 7+ days only every 5 minutes", async () => {
    await register();
    const later = T0 + 8 * 86_400_000;
    const minute0 = Math.ceil(later / 300_000) * 300_000; // a minute where (minute % 5) == 0
    const uidSlot = 42 % 5;
    const slot = minute0 + uidSlot * 60_000;
    expect((await dueUsers(env, slot)).length).toBe(1);
    expect((await dueUsers(env, slot + 60_000)).length).toBe(0);
    expect((await dueUsers(env, slot + 300_000)).length).toBe(1);
    // active device: every minute
    expect((await dueUsers(env, T0 + 60_000)).length).toBe(1);
    expect((await dueUsers(env, T0 + 120_000)).length).toBe(1);
  });
});

describe("daily cleanup", () => {
  it("deletes devices unseen 30 days and users without devices", async () => {
    await register("good-token-1234", "aa".repeat(32), undefined, T0, 42);
    await register("good-token-5678", "bb".repeat(32), undefined, T0 + 29 * 86_400_000, 43);
    await dailyCleanup(env, T0 + 31 * 86_400_000);
    expect(await devCount()).toBe(1);
    const users = (await env.DB.prepare("SELECT uid FROM users").all<any>()).results;
    expect(users.map((x) => x.uid)).toEqual([43]);
  });
});
