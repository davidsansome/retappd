import type { Env } from "./env";
import { handleRequest } from "./api";
import { FetchApnsSender } from "./apns";
import { log, safeErr } from "./log";
import { cleanRateLimits, dailyCleanup, runPoll } from "./poll";

export default {
  fetch: (req: Request, env: Env) => handleRequest(req, env),
  async scheduled(controller: ScheduledController, env: Env) {
    const now = controller.scheduledTime || Date.now();
    if (controller.cron === "17 3 * * *") await dailyCleanup(env, now);
    else {
      if (Math.floor(now / 60_000) % 60 === 0) {
        try {
          await cleanRateLimits(env, now);
        } catch (e) {
          log("clean_rate_limits_failed", { error: safeErr(e) });
        }
      }
      await runPoll(env, { apns: new FetchApnsSender(env), now });
    }
  },
} satisfies ExportedHandler<Env>;
