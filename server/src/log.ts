// Allowlisted structured logging. Never pass tokens, secrets or Untappd content here.
export function log(event: string, fields: Record<string, string | number | boolean | undefined> = {}) {
  console.log(JSON.stringify({ event, ...fields }));
}

/** Error name/code only; messages from libraries could echo inputs, so they are dropped. */
export function safeErr(e: unknown): string {
  return e instanceof Error ? e.name : "UnknownError";
}
