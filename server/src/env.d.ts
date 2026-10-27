interface Env {
  ROOMS: DurableObjectNamespace<import("./room").Room>;
  /** Private bucket with the app's releases; see update.ts. Not set where no bucket is bound. */
  RELEASES?: R2Bucket;
  /**
   * Shared secret every client must present, set with `wrangler secret put ROOM_KEY`. When it is not
   * set (local development) the server is open.
   */
  ROOM_KEY?: string;
  /**
   * The keys that sign pushes to browsers (see push.ts): `wrangler secret put VAPID_PRIVATE`, and the public half in
   * VAPID_PUBLIC. Without them the server sends no pushes and says so to a device that asks for them.
   */
  VAPID_PRIVATE?: string;
  VAPID_PUBLIC?: string;
  /** Who runs the server, for the push services; a default is used without it. */
  VAPID_SUBJECT?: string;
  /** Only the tests set these: pushes may go to a service on this machine, and a device counts as away this soon (ms). */
  PUSH_LOCAL?: string;
  PUSH_FRESH_MS?: string;
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
