interface Env {
  ROOMS: DurableObjectNamespace<import("./room").Room>;
  /** One per cluster of a person's devices (Connect); see connect.ts. */
  CONNECT: DurableObjectNamespace<import("./connect").Connect>;
  /** Private bucket with the app's releases; see update.ts. Not set where no bucket is bound. */
  RELEASES?: R2Bucket;
  /** Private bucket with the pictures sent in chat, encrypted by the sender; see media.ts. Not set where no bucket is bound. */
  MEDIA?: R2Bucket;
  /** Counts what the pictures of all rooms take together. */
  LEDGER: DurableObjectNamespace<import("./media").MediaLedger>;
  /** Secret that signs the tickets to put a picture in the bucket: `wrangler secret put MEDIA_SIGN`. Without it the server takes no pictures. */
  MEDIA_SIGN?: string;
  /** Limits of the pictures (bytes, count, milliseconds) the tests shorten: a file, a room, the account, files a member asks for in a day, a ticket's life. */
  MEDIA_FILE_MAX?: string;
  MEDIA_ROOM_MAX?: string;
  MEDIA_ACCOUNT_MAX?: string;
  MEDIA_PER_DAY?: string;
  MEDIA_TICKET_MS?: string;
  /** Limits of requests for one address in a minute (wrangler.jsonc); not set where nothing is bound, as in the tests. */
  LIMIT_ROOMS?: RateLimit;
  LIMIT_YT?: RateLimit;
  LIMIT_JOIN?: RateLimit;
  LIMIT_LASTFM?: RateLimit;
  LIMIT_SYNC?: RateLimit;
  LIMIT_CONNECT?: RateLimit;
  /**
   * Last.fm (see lastfm.ts): the API key of the account made at last.fm/api/account/create is in `vars` of wrangler.jsonc (it is
   * not secret: it is in the address of the page where a person allows the app), and its shared secret is a secret:
   * `wrangler secret put LASTFM_SECRET`. Without both the server answers 503 and the apps hide Last.fm.
   */
  /** How long (ms) the playing device has to hand its queue over in Connect before the last one kept is used; only the tests shorten it. */
  CONNECT_HANDOFF_MS?: string;
  /** How old (ms) the newest old version of a synced library must be before the next is kept; only the tests shorten it (see sync.ts). */
  SYNC_VERSION_GAP_MS?: string;
  LASTFM_KEY?: string;
  LASTFM_SECRET?: string;
  /** Only the tests set this: where Last.fm is asked instead of its real address. */
  LASTFM_API?: string;
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
  /** How long the device asked for songs by autoplay has to answer before the next is asked (milliseconds); only the tests set it. */
  FILL_MS?: string;
  /**
   * Timers the tests shorten, in milliseconds: how long a silent device is kept before it is dropped,
   * how often a room looks for such devices, and how long an empty room is kept with and without songs queued.
   */
  DROP_MS?: string;
  SWEEP_MS?: string;
  EMPTY_MS?: string;
  EMPTY_BARE_MS?: string;
  /** How long the chat is kept, the most messages kept, and how often old ones are looked for (the tests shorten these). */
  CHAT_KEEP_MS?: string;
  CHAT_KEEP_MAX?: string;
  CHAT_PRUNE_MS?: string;
}
