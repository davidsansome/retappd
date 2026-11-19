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
    expect(Number(row.friend_marker)).toBe(T1 - 60_000); // minus clock-skew allowance
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
    u.counts = { comments: 1, toasts: 1, others: 2 };
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

describe("count-based new-item detection", () => {
  const T1 = T0 + 60_000;
  const pushed = () => apns.sent.map((x) => x.payload.retappd.checkin_id);

  it("read elsewhere then new activity within one interval: only the new one is pushed", async () => {
    await register();
    await poll(T1);
    // X arrived and was read in another app (counts back to 0), then Y arrived: counter says 1 unread.
    u.items = [toastItem(2, T1 + 50_000), toastItem(1, T1 + 10_000)];
    u.counts = { toasts: 1 };
    await poll(T1 + 60_000);
    expect(pushed()).toEqual([2]);
    expect(Number((await user()).marker)).toBe(T1 + 50_000); // X is marked handled too
  });

  it("two items in the same second across polls are both pushed exactly once", async () => {
    await register();
    await poll(T1);
    const t = T1 + 30_000;
    u.items = [toastItem(10, t)];
    u.counts = { toasts: 1 };
    await poll(T1 + 60_000);
    u.items = [toastItem(11, t), toastItem(10, t)];
    u.counts = { toasts: 1 };
    await poll(T1 + 120_000);
    u.counts = { toasts: 1 }; // counter noise: nothing new in the list
    await poll(T1 + 180_000);
    expect(pushed()).toEqual([10, 11]);
  });

  it("friend request withdrawn and re-sent pushes again", async () => {
    await register();
    await poll(T1);
    u.pending = [pendingReq(T1 + 10_000)];
    u.counts = { friends: 1 };
    await poll(T1 + 60_000);
    u.pending = [];
    u.counts = {};
    await poll(T1 + 120_000);
    u.pending = [pendingReq(T1 + 130_000)];
    u.counts = { friends: 1 };
    await poll(T1 + 180_000);
    expect(apns.sent).toHaveLength(2);
  });

  it("a re-toast counter rise with only stale unhandled items is bounded by the 24h cap", async () => {
    await register();
    await poll(T1);
    u.items = [toastItem(20, T1 + 600_000)]; // read elsewhere long ago
    u.counts = { toasts: 1 }; // overcount from a re-toast without a list item
    await poll(T1 + 3 * 86_400_000);
    expect(apns.sent).toEqual([]);
  });

  it("a long backoff (beyond the 1h cap) loses nothing on recovery", async () => {
    await register();
    await poll(T1);
    await env.DB.prepare("UPDATE users SET fail_count = 20, next_poll_at = ?").bind(T1 + 3_600_000).run();
    const later = T1 + 5 * 3_600_000;
    u.items = [toastItem(30, later - 3 * 3_600_000)]; // arrived 3 hours before recovery
    u.counts = { toasts: 1 };
    await poll(later);
    expect(pushed()).toEqual([30]);
    expect((await user()).fail_count).toBe(0);
  });

  it("stale users polled irregularly (skipped cron minutes) still get old unread items", async () => {
    await register();
    await poll(T1);
    const later = Math.ceil((T0 + 8 * 86_400_000) / 300_000) * 300_000 + (42 % 5) * 60_000; // uid 42's slot
    expect((await dueUsers(env, later)).length).toBe(1);
    u.items = [toastItem(40, later - 25 * 60_000)];
    u.counts = { toasts: 1 };
    await poll(later);
    expect(pushed()).toEqual([40]);
  });

  it("sharding keeps a stable schedule: each user once per POLL_SHARDS minutes, never flipping", async () => {
    for (let uid = 1; uid <= 7; uid++) await register("good-token-" + uid + "xx", String(uid).repeat(64), undefined, T0, uid);
    const sharded = testEnv({ POLL_SHARDS: "3" });
    const m0 = Math.floor(T0 / 60_000) * 60_000 + 60_000;
    const counts = new Map<number, number[]>();
    for (let i = 0; i < 9; i++)
      for (const x of await dueUsers(sharded, m0 + i * 60_000)) counts.set(x.uid, [...(counts.get(x.uid) ?? []), i]);
    expect(counts.size).toBe(7);
    for (const [uid, minutes] of counts) {
      expect(minutes).toHaveLength(3);
      expect(minutes[1] - minutes[0]).toBe(3);
      expect(minutes[2] - minutes[1]).toBe(3);
      void uid;
    }
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
