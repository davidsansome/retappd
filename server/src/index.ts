import type { Env } from "./env";
import { handleRequest } from "./api";
import { FetchApnsSender } from "./apns";
import { dailyCleanup, runPoll } from "./poll";

export default {
  fetch: (req: Request, env: Env) => handleRequest(req, env),
  async scheduled(controller: ScheduledController, env: Env) {
    if (controller.cron === "17 3 * * *") await dailyCleanup(env, Date.now());
    else await runPoll(env, { apns: new FetchApnsSender(env), now: Date.now() });
  },
} satisfies ExportedHandler<Env>;
