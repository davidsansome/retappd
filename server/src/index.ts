import type { Env } from "./env";
import { handleRequest } from "./api";
import { FetchApnsSender } from "./apns";
import { cleanRateLimits, dailyCleanup, runPoll } from "./poll";

export default {
  fetch: (req: Request, env: Env) => handleRequest(req, env),
  async scheduled(controller: ScheduledController, env: Env) {
    if (controller.cron === "17 3 * * *") await dailyCleanup(env, Date.now());
    else {
      const now = Date.now();
      if (Math.floor(now / 60_000) % 60 === 0) await cleanRateLimits(env, now);
      await runPoll(env, { apns: new FetchApnsSender(env), now });
    }
  },
} satisfies ExportedHandler<Env>;
