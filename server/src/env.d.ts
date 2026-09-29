interface Env {
  ROOMS: DurableObjectNamespace<import("./room").Room>;
  /**
   * Shared secret every client must present, set with `wrangler secret put ROOM_KEY`. When it is not
   * set (local development) the server is open.
   */
  ROOM_KEY?: string;
  /** Overrides how long a silent device stays present before it is marked away (milliseconds); only the tests set it. */
  STALE_MS?: string;
}
