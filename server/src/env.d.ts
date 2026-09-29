interface Env {
  ROOMS: DurableObjectNamespace<import("./room").Room>;
  /**
   * Shared secret every client must present, set with `wrangler secret put ROOM_KEY`. When it is not
   * set (local development) the server is open.
   */
  ROOM_KEY?: string;
  /** Overrides how long a silent device stays present before it is marked away (milliseconds); only the tests set it. */
  STALE_MS?: string;
  /**
   * Timers the tests shorten, in milliseconds: how long a silent device is kept before it is dropped,
   * how often a room looks for such devices, and how long an empty room is kept with and without songs queued.
   */
  DROP_MS?: string;
  SWEEP_MS?: string;
  EMPTY_MS?: string;
  EMPTY_BARE_MS?: string;
}
