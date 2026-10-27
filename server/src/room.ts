import { DurableObject } from "cloudflare:workers";
import { PROTOCOL_VERSION, REACTIONS, isEmoji } from "./protocol";
import { sendWebPush, readSubscription } from "./push";
import type { VapidKeys, WebPushSubscription } from "./push";
import type {
  AlarmKind,
  ChatMessage,
  ChatQuote,
  ChatReceipt,
  ClientMessage,
  GuestControl,
  Member,
  PublicState,
  QueueItem,
  Reaction,
  Repeat,
  RoomState,
  ServerMessage,
  TrackInput,
} from "./protocol";

/**
 * How far in the future a start is scheduled, so every device has time to receive and arm it. This is the most; when
 * every device following the room says what its round trip is, the lead is the slowest of them plus LEAD_MARGIN_MS,
 * and no less than MIN_LEAD_MS, so that play and seek answer sooner on good networks.
 */
const LEAD_MS = 1500;
const MIN_LEAD_MS = 600;
/** Covers the start message's way down, jitter, and the seek a device makes before the moment comes. */
const LEAD_MARGIN_MS = 400;
/** How long to wait for slow devices to report ready before starting without them. */
const BARRIER_TIMEOUT_MS = 8000;
/** Extra time after the expected end of an item before the server advances on its own. */
const END_GRACE_MS = 5000;
/** A gapless advance report must describe a start that happened at most this long ago. */
const ADVANCE_MAX_AGE_MS = 10_000;
/** Tolerated clock error for a start time that lies slightly in the future. */
const ADVANCE_FUTURE_SLACK_MS = 500;
/** An advance more than this far before the item's expected end is ignored. */
const ADVANCE_EARLY_LIMIT_MS = 15_000;
/**
 * A device that has been silent this long (it pings every 30 seconds) is marked away: it does not
 * count as listening and never holds the room back. Overridable for tests through STALE_MS.
 */
/** A device of the same name coming in makes an entry quiet for this long (a ping comes every 30 s) count as its ghost. */
const GHOST_AFTER_MS = 45_000;
const AWAY_AFTER_MS = 75_000;
/** A device silent this long is dropped: its connection is dead even though it never closed. Overridable for tests through DROP_MS. */
const DROP_AFTER_MS = 150_000;
/** How long an empty room that still has songs queued keeps its state: long enough to come back to next weekend. */
const EMPTY_ROOM_TTL_MS = 7 * 24 * 60 * 60 * 1000;
/** How long an empty room with nothing queued is kept: there is nothing to come back to. */
const EMPTY_BARE_ROOM_TTL_MS = 60 * 60 * 1000;
/** How often a room with members looks for devices past DROP_AFTER_MS, so a room of dead connections still empties. Overridable for tests through SWEEP_MS. */
const DROP_CHECK_MS = 5 * 60 * 1000;

const MAX_MEMBERS = 12;
const MAX_ROOM_NAME = 32;
/** A theme is a short name the apps know; the server only checks its shape, so a new look needs no deploy. */
const THEME_NAME = /^[a-z0-9-]{1,24}$/;
const BASE64 = /^[A-Za-z0-9+/=]+$/;
const MAX_QUEUE = 200;
const MAX_MESSAGE_CHARS = 32_768;
/** The one message that may be longer: `room.theme` with the picture behind the chat. Protocol 16. */
const MAX_THEME_MESSAGE_CHARS = 98_304;
const MAX_BACKGROUND_CHARS = 90_000;
/** What the picture behind the chat is asked for as (`avatar.get`): no member's public id looks like it. */
const BACKGROUND_ID = "room:bg";
const BACKGROUND_KEY = "background";
/** A picture is sent as base64 of a small JPEG (about 256 px); anything bigger is refused. */
const MAX_AVATAR_CHARS = 24_000;
const AVATAR_PREFIX = "avatar:";
/** Songs accepted from one queue.addMany message. */
const MAX_ADD_MANY = 100;
const MAX_MESSAGES_PER_SECOND = 20;
/** A chat message is cut to this many characters. */
const MAX_CHAT_CHARS = 500;
/** How many of the last chat messages a device is given on joining; older ones it asks for by page. */
const CHAT_KEPT = 100;
/** The key the chat was kept under before it had a table (an array of the last [CHAT_KEPT] messages). */
const CHAT_KEY = "chat";
/** A chat message is kept this long, and the room with it when nobody comes back: 180 days. */
const CHAT_KEEP_MS = 180 * 24 * 60 * 60 * 1000;
/** And no more than this many of them, whichever comes first. */
const CHAT_KEEP_MAX = 5000;
/** Most messages one page of older chat holds, and how many it holds when the device does not say. */
const CHAT_PAGE_MAX = 100;
const CHAT_PAGE = 50;
/** Old messages are looked for at most this often while the room is busy. */
const CHAT_PRUNE_EVERY_MS = 60 * 60 * 1000;
const RECEIPTS_KEY = "chatReceipts";
/** A reply shows this many characters of the message it answers. */
const QUOTE_CHARS = 100;
/** Members that can have a reaction on one message; a room never has so many at once, so this only bounds a message. */
const MAX_REACTORS = 32;
const KNOWN_REACTIONS = new Set<string>(REACTIONS);
/** Taps on a reaction that one message may carry. */
const MAX_REACTION_COUNT = 10;
/** A device that asked for pushes is kept under this key plus its public id. */
const PUSH_PREFIX = "push:";
/** A device away longer than this is no longer told of the chat: it is not really in the room any more. */
const PUSH_FRESH_MS = 12 * 60 * 60 * 1000;
/** A notice shows this many characters of the message it is about. */
const PUSH_PREVIEW_CHARS = 120;
/** The most a sealed message and a sealed preview take, in characters of base64: 500 characters of any script fit. */
const MAX_SEALED_CHARS = 4096;
const MAX_SEALED_PREVIEW_CHARS = 600;
/** What a sealed message is made of: base64url. */
const SEALED = /^[A-Za-z0-9_-]+$/;
/** The close code of a device that must update the app to be in a room (end-to-end encryption). */
const CLOSE_NEEDS_UPDATE = 4005;
const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;

/** A browser that asked to be told of the chat while it is away. */
interface PushDevice {
  sub: WebPushSubscription;
  /** The room code, for the notice to open the room it is about. */
  room: string;
  /** The last time it was in the room: now while it is, when its connection closed otherwise. */
  seen: number;
  /** Quiet until this server time (ms); absent when not. */
  until?: number;
  /** False keeps the text of the messages out of its notices. */
  preview?: false;
  /** The language its notices are written in, as the app said. */
  lang?: string;
}

/** What a notice is about: a new message, an answer to one's own, or a reaction to one's own. */
type PushKind = "chat" | "reply" | "react";

interface Attachment {
  /** The device's own secret id: only it knows it, and it proves the device is the same one when it reconnects. */
  clientId: string;
  /** What everybody else knows the device by (members, owner, who added or skipped): derived from [clientId], never the other way round. */
  id: string;
  name: string;
  /** Last time this socket sent anything; clients ping every 30 seconds. */
  lastSeen: number;
  /** Listening on their own, so the room does not wait for or move this device. */
  solo: boolean;
  /** When this device joined; the longest present member takes over when the owner leaves. */
  joinedAt?: number;
  /** Fingerprint of this member's picture; the picture is in storage, since an attachment holds only 2 KiB. */
  av?: string;
  /** The best round trip the device measured, as it last said in a ping; absent from older apps. */
  rtt?: number;
  /** The app can read and write sealed chat (it said "e2ee" when joining). */
  e2ee?: boolean;
}

/** What only the owner may do once the owner has restricted guests to adding songs. */
const CONTROL_MESSAGES = new Set([
  "queue.remove",
  "queue.swap",
  "queue.clear",
  "queue.shuffle",
  "queue.move",
  "jump",
  "play",
  "pause",
  "seek",
  "next",
  "prev",
  "repeat",
  "autoplay",
  "shuffle",
  "room.name",
  "room.theme",
]);

/** The fields of a song as the queue keeps them, cut to size. */
function cleanTrack(track: TrackInput) {
  return {
    videoId: track.videoId,
    title: String(track.title ?? "").slice(0, 200),
    artist: String(track.artist ?? "").slice(0, 100),
    thumb: typeof track.thumb === "string" ? track.thumb.slice(0, 300) : undefined,
    durMs: clamp(Number(track.durMs) || 0, 0, 12 * 3600 * 1000),
  };
}

function millis(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return parsed > 0 ? parsed : fallback;
}

function defaultState(): RoomState {
  return {
    queue: [],
    index: 0,
    phase: "idle",
    startedAt: 0,
    positionMs: 0,
    repeat: "off",
    epoch: 0,
    readyIds: [],
    failedIds: [],
    guestControl: "all",
    autoplay: true,
    shuffle: false,
    alarms: {},
  };
}

export class Room extends DurableObject<Env> {
  private s: RoomState = defaultState();
  /** Per-socket rate limiting. Lives in memory only; losing it on hibernation is harmless. */
  private buckets = new WeakMap<WebSocket, { tokens: number; last: number }>();
  /** Membership as last broadcast; a change in who is away or solo is sent without waiting for a socket to close. */
  private membersKey = "";
  /** The room was made on purpose (or by an older app) and has not expired; stops a mistyped code from opening an empty room. */
  private created = false;
  /**
   * The last [CHAT_KEPT] chat messages, oldest first: what a device joining is given. The rest are in the `messages`
   * table, apart from the state, so that saving the state does not write any of them again.
   */
  private chat: ChatMessage[] = [];
  /** When old chat messages were last looked for. */
  private prunedAt = 0;
  /** What each member has got of the chat, by public id. Kept apart from the messages for the same reason. */
  private receipts: Record<string, ChatReceipt> = {};

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      await this.openChat();
      this.receipts = (await ctx.storage.get<Record<string, ChatReceipt>>(RECEIPTS_KEY)) ?? {};
      const saved = await ctx.storage.get<RoomState & { alarm?: string }>("state");
      if (!saved) return;
      // Fields added after a room was saved get their defaults
      const { alarm, ...rest } = saved;
      this.s = { ...defaultState(), ...rest };
      this.created = true;
      await this.migrateIds();
      // A room saved with the single alarm it had before: carry that alarm's time over
      const at = await ctx.storage.getAlarm();
      if (at && (alarm === "barrier" || alarm === "end" || alarm === "gc")) this.s.alarms[alarm] = at;
    });
  }

  // ------------------------------------------------------------------ connections

  async fetch(request: Request): Promise<Response> {
    if (request.method === "GET" && new URL(request.url).pathname.endsWith("/info")) {
      return Response.json(this.info());
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (typeof raw !== "string" || raw.length > MAX_THEME_MESSAGE_CHARS) {
      return this.fail(ws, "bad_message", `Message must be text of at most ${MAX_MESSAGE_CHARS} characters`);
    }
    if (!this.allow(ws)) return this.fail(ws, "rate_limited", "Too many messages");
    this.touch(ws);
    // Every message is a chance to notice a device that went quiet
    await this.sweep();

    let msg: ClientMessage;
    try {
      msg = JSON.parse(raw) as ClientMessage;
    } catch {
      return this.fail(ws, "bad_json", "Invalid JSON");
    }
    if (typeof msg !== "object" || msg === null || typeof msg.t !== "string") {
      return this.fail(ws, "bad_message", "Missing message type");
    }
    if (raw.length > MAX_MESSAGE_CHARS && msg.t !== "room.theme") {
      return this.fail(ws, "bad_message", `Message must be text of at most ${MAX_MESSAGE_CHARS} characters`);
    }

    if (msg.t === "ping") {
      if (typeof msg.c0 !== "number") return this.fail(ws, "bad_message", "ping needs c0");
      this.noteRoundTrip(ws, msg.rtt);
      return this.send(ws, { t: "pong", c0: msg.c0, s1: Date.now() });
    }
    if (msg.t === "join") return this.onJoin(ws, msg);

    const me = ws.deserializeAttachment() as Attachment | null;
    if (!me) return this.fail(ws, "not_joined", "Send join first");
    if (CONTROL_MESSAGES.has(msg.t) && !this.canControl(me.id)) {
      return this.fail(ws, "forbidden", "Only the room's owner can do that");
    }

    switch (msg.t) {
      case "queue.add": return this.onQueueAdd(me, msg);
      case "queue.addMany": return this.onQueueAddMany(me, msg);
      case "queue.remove": return this.onQueueRemove(msg.id);
      case "queue.swap": return this.onQueueSwap(me, msg);
      case "queue.clear": return this.onQueueClear();
      case "queue.shuffle": return this.onQueueShuffle(me.id);
      case "jump": return this.onJump(msg.id, me.id);
      case "queue.move": return this.onQueueMove(msg.id, msg.toIndex);
      case "play": return this.onPlay(me.id);
      case "pause": return this.onPause(me.id);
      case "seek": return this.onSeek(msg.positionMs, me.id);
      // Pressed on a song the room has already left (somebody else skipped first): the room has moved on already
      case "next": return this.pressedOnCurrent(msg.from) ? this.onNext(me.id) : undefined;
      case "prev": return this.pressedOnCurrent(msg.from) ? this.onPrev(me.id) : undefined;
      case "repeat": return this.onRepeat(msg.mode);
      case "autoplay": return this.onAutoplay(msg.on);
      case "shuffle": return this.onShuffle(msg.on);
      case "solo": return this.onSolo(me, msg.on === true);
      case "avatar.set": return this.onAvatarSet(me, msg.data);
      case "avatar.get": return this.onAvatarGet(ws, msg.id);
      case "bye": return this.onBye(ws, me);
      case "kick": return this.onKick(ws, me, msg.id);
      case "room.name": return this.onRoomName(msg.name);
      case "room.theme": return this.onRoomTheme(msg.theme, msg.bg);
      case "room.settings": return this.onRoomSettings(ws, me, msg.guestControl);
      case "resync": return this.onResync(ws, me);
      case "ready": return this.onReady(me.id, msg.epoch);
      case "resolveFailed": return this.onResolveFailed(me.id, msg.epoch);
      case "ended": return this.onEnded(msg.epoch);
      case "advanced": return this.onAdvanced(msg.epoch, msg.itemId, msg.startedAt);
      case "chat": return this.onChat(me, msg.text, msg.cid, msg.reply, msg.ct, msg.pv);
      case "room.encrypt": return this.onRoomEncrypt(ws, me);
      case "chat.react": return this.onChatReact(me, msg.id, msg.e);
      case "chat.before": return this.onChatBefore(ws, msg.id, msg.n);
      case "chat.receipt": return this.onChatReceipt(me, msg.delivered, msg.read);
      case "push.set": return this.onPushSet(ws, me, msg);
      case "push.clear": return this.ctx.storage.delete(PUSH_PREFIX + me.id).then(() => undefined);
      case "react": return this.onReact(me, msg.e, msg.n);
      case "report": return; // diagnostics only for now
      default: return this.fail(ws, "unknown_type", `Unknown message type`);
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    ws.close(1000, "closed");
    await this.notePushSeen(ws);
    await this.onMembersChanged();
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    ws.close(1011, "error");
    await this.notePushSeen(ws);
    await this.onMembersChanged();
  }

  private async onJoin(ws: WebSocket, msg: Extract<ClientMessage, { t: "join" }>): Promise<void> {
    const clientId = typeof msg.clientId === "string" ? msg.clientId.slice(0, 64) : "";
    const name = typeof msg.name === "string" ? msg.name.trim().slice(0, 32) : "";
    if (!clientId || !name) return this.fail(ws, "bad_message", "join needs clientId and name");
    const id = await publicId(clientId);

    // The same device reconnecting: drop its stale socket. A quiet entry of the same name under another id is
    // taken for the same device's ghost (it came back with a new id, after a reinstall or cleared data): it goes
    // now, instead of two of them being listed until the ghost is swept
    const quietFor = Math.min(Number(this.env.STALE_MS) || AWAY_AFTER_MS, GHOST_AFTER_MS);
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      const att = other.deserializeAttachment() as Attachment | null;
      if (att?.clientId === clientId) other.close(1000, "replaced by a newer connection");
      else if (att && att.name === name && Date.now() - att.lastSeen > quietFor) other.close(1001, "replaced by a device of the same name");
    }
    if (msg.create === false && !this.created) {
      this.fail(ws, "room_not_found", "There is no room with this code");
      ws.close(4004, "room not found");
      return;
    }
    if (this.members().length >= MAX_MEMBERS && !this.members().some((m) => m.id === id)) {
      this.fail(ws, "room_full", "The room is full");
      ws.close(1008, "room is full");
      return;
    }
    const e2ee = Array.isArray(msg.caps) && msg.caps.includes("e2ee");
    if (this.s.enc && !e2ee) {
      this.fail(ws, "needs_update", "This room is end-to-end encrypted: update the app to be in it");
      ws.close(CLOSE_NEEDS_UPDATE, "needs update");
      return;
    }

    // A second join on the same socket is a rename: keep the listening mode and the place in line
    const before = ws.deserializeAttachment() as Attachment | null;
    const now = Date.now();
    // A device that comes back keeps the picture it had, so it does not vanish from the others' screens meanwhile
    const kept = await this.ctx.storage.get<string>(AVATAR_PREFIX + id);
    const av = kept === undefined ? undefined : await fingerprint(kept);
    ws.serializeAttachment(
      { clientId, id, name, lastSeen: now, solo: before?.solo ?? false, joinedAt: before?.joinedAt ?? now, av, e2ee } satisfies Attachment,
    );

    // The first to arrive owns a room that has no owner; the room now exists and someone is in it
    this.created = true;
    const adopted = !this.s.ownerId;
    if (adopted) this.s.ownerId = id;
    delete this.s.alarms.gc;
    if (!this.s.alarms.sweep) this.s.alarms.sweep = now + this.dropCheckMs();
    await this.armAlarm();

    if (adopted) this.broadcastState();
    else this.send(ws, this.stateMessage(id));
    this.send(ws, { t: "chat.history", msgs: this.chat, receipts: this.receipts, more: this.chatBefore(this.chat[0]?.id) });
    // A device joining mid-preparation must take part in the barrier
    if (this.s.phase === "preparing") this.send(ws, this.prepareMessage());
    this.broadcastMembers();
  }

  private async onMembersChanged(): Promise<void> {
    const members = this.members();
    if (members.length === 0) {
      // A socket that never joined a room that does not exist is nothing to keep
      if (!this.created) return;
      // Nobody is listening: freeze the position, let go of the ownership and schedule cleanup. A song still loading
      // waits paused too, or it would start by itself for whoever comes back
      if (this.s.phase === "playing") {
        this.s.positionMs = this.currentPositionMs();
        this.s.phase = "paused";
        this.s.epoch++;
      } else if (this.s.phase === "preparing") {
        this.s.phase = "paused";
        this.s.epoch++;
      }
      this.s.readyIds = [];
      this.s.failedIds = [];
      delete this.s.ownerId;
      this.s.guestControl = "all";
      delete this.s.alarms.barrier;
      delete this.s.alarms.end;
      delete this.s.alarms.sweep;
      this.s.alarms.gc = Date.now() + this.emptyTtlMs();
      await this.armAlarm();
      return;
    }
    await this.dropPicturesOfAbsentMembers(members);
    this.broadcastMembers();
    await this.maybeStart(); // the device we were waiting for may be the one that left
  }

  /** A picture is kept only while its owner is here: a device that comes back sends it again. */
  private async dropPicturesOfAbsentMembers(members: Member[]): Promise<void> {
    const present = new Set(members.map((m) => AVATAR_PREFIX + m.id));
    const kept = await this.ctx.storage.list({ prefix: AVATAR_PREFIX });
    const gone = [...kept.keys()].filter((key) => !present.has(key));
    if (gone.length) await this.ctx.storage.delete(gone);
  }

  /**
   * Keeps a chat message and hands it to everybody, its sender too. A message with no text is ignored. [reply] is the
   * number of the message it answers; one the room no longer has is left out and the text goes on its own.
   */
  private async onChat(me: Attachment, text: unknown, cid: unknown, reply: unknown, ct?: unknown, pv?: unknown): Promise<void> {
    const sealed = this.s.enc === true;
    let clean = "";
    if (sealed) {
      // The words are sealed: all the room can check is how much there is of them
      if (typeof ct !== "string" || !ct || ct.length > MAX_SEALED_CHARS || !SEALED.test(ct)) return;
      if (pv !== undefined && (typeof pv !== "string" || pv.length > MAX_SEALED_PREVIEW_CHARS || !SEALED.test(pv))) return;
    } else {
      if (typeof text !== "string") return;
      // Cut by characters, not UTF-16 units, so an emoji at the end is not split in half
      clean = Array.from(text.trim()).slice(0, MAX_CHAT_CHARS).join("").trimEnd();
      if (!clean) return;
    }
    const quoted = typeof reply === "number" ? this.chatMessage(reply) : undefined;
    const msg: ChatMessage = {
      id: (this.chat.at(-1)?.id ?? 0) + 1,
      by: me.id,
      name: me.name,
      text: clean,
      at: Date.now(),
      ...(typeof cid === "string" && cid ? { cid: cid.slice(0, 40) } : {}),
      // A sealed message carries what it answers inside; the room has no words to quote
      ...(quoted && !sealed ? { re: quote(quoted) } : {}),
      ...(sealed ? { ct: ct as string, ...(typeof pv === "string" ? { pv } : {}) } : {}),
    };
    this.chat.push(msg);
    if (this.chat.length > CHAT_KEPT) this.chat.splice(0, this.chat.length - CHAT_KEPT);
    this.saveChatMessage(msg);
    this.pruneChat(false);
    // Writing a message is looking at the chat up to it: the others learn it with their next receipt
    this.receipts[me.id] = { d: msg.id, r: msg.id };
    this.pruneReceipts();
    await this.ctx.storage.put(RECEIPTS_KEY, this.receipts);
    this.broadcast({ t: "chat", msg });
    await this.pushNotice(me, sealed ? undefined : clean, (id) => (quoted?.by === id ? "reply" : "chat"), undefined, { pv: msg.pv, author: me.id });
  }

  /**
   * Turns on end-to-end encryption for good. The messages so far were written in the clear, so they go now, and with
   * them what each member had got of them; devices that cannot read sealed messages are let go.
   */
  private async onRoomEncrypt(ws: WebSocket, me: Attachment): Promise<void> {
    if (me.id !== this.s.ownerId) return this.fail(ws, "forbidden", "Only the room's owner can do that");
    if (this.s.enc) return;
    this.s.enc = true;
    this.ctx.storage.sql.exec("DELETE FROM messages");
    this.chat = [];
    this.receipts = {};
    await this.ctx.storage.put(RECEIPTS_KEY, this.receipts);
    await this.save();
    for (const other of this.ctx.getWebSockets()) {
      const att = other.deserializeAttachment() as Attachment | null;
      if (att && !att.e2ee) {
        this.fail(other, "needs_update", "This room is end-to-end encrypted: update the app to be in it");
        other.close(CLOSE_NEEDS_UPDATE, "needs update");
      }
    }
    this.broadcastState();
    this.broadcast({ t: "chat.history", msgs: [], receipts: {}, more: false });
  }

  /** Sets, or with null takes away, this member's reaction to a chat message, and sends the message again. */
  private async onChatReact(me: Attachment, id: unknown, e: unknown): Promise<void> {
    const msg = typeof id === "number" ? this.chatMessage(id) : undefined;
    if (!msg) return;
    const rx = { ...msg.rx };
    if (e === null || e === undefined) {
      if (!(me.id in rx)) return;
      delete rx[me.id];
    } else {
      if (typeof e !== "string" || !(KNOWN_REACTIONS.has(e) || isEmoji(e))) return;
      if (rx[me.id] === e || (!(me.id in rx) && Object.keys(rx).length >= MAX_REACTORS)) return;
      rx[me.id] = e;
    }
    if (Object.keys(rx).length > 0) msg.rx = rx;
    else delete msg.rx;
    this.saveChatMessage(msg);
    this.broadcast({ t: "chat.update", msg });
    // The author of the message is told of a reaction given to it; taking one away is no news
    if (typeof e === "string" && msg.by !== me.id) {
      await this.pushNotice(me, msg.ct ? undefined : msg.text, (id) => (id === msg.by ? "react" : null), e, { pv: msg.pv, author: msg.by });
    }
  }

  // ------------------------------------------------------------------ the chat's table

  /** Makes the table of messages, and moves into it the chat of a room that predates it. Loads the last messages. */
  private async openChat(): Promise<void> {
    const sql = this.ctx.storage.sql;
    sql.exec(
      "CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, at INTEGER NOT NULL, author TEXT NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL, cid TEXT, re TEXT, rx TEXT, ct TEXT, pv TEXT)",
    );
    sql.exec("CREATE INDEX IF NOT EXISTS messages_at ON messages (at)");
    const legacy = await this.ctx.storage.get<ChatMessage[]>(CHAT_KEY);
    if (legacy) {
      this.ctx.storage.transactionSync(() => {
        for (const msg of legacy) this.saveChatMessage(msg);
      });
      await this.ctx.storage.delete(CHAT_KEY);
    }
    this.chat = this.readMessages("SELECT * FROM messages ORDER BY id DESC LIMIT ?", CHAT_KEPT).reverse();
  }

  private readMessages(query: string, ...bindings: (string | number)[]): ChatMessage[] {
    return this.ctx.storage.sql.exec(query, ...bindings).toArray().map((row) => ({
      id: row.id as number,
      by: row.author as string,
      name: row.name as string,
      text: row.text as string,
      at: row.at as number,
      ...(row.cid ? { cid: row.cid as string } : {}),
      ...(row.ct ? { ct: row.ct as string } : {}),
      ...(row.pv ? { pv: row.pv as string } : {}),
      ...(row.re ? { re: JSON.parse(row.re as string) as ChatQuote } : {}),
      ...(row.rx ? { rx: JSON.parse(row.rx as string) as Record<string, string> } : {}),
    }));
  }

  private saveChatMessage(msg: ChatMessage): void {
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO messages (id, at, author, name, text, cid, re, rx, ct, pv) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      msg.id,
      msg.at,
      msg.by,
      msg.name,
      msg.text,
      msg.cid ?? null,
      msg.re ? JSON.stringify(msg.re) : null,
      msg.rx ? JSON.stringify(msg.rx) : null,
      msg.ct ?? null,
      msg.pv ?? null,
    );
  }

  /** A message of the room, among the last ones or from further back. */
  private chatMessage(id: number): ChatMessage | undefined {
    return this.chat.find((m) => m.id === id) ?? this.readMessages("SELECT * FROM messages WHERE id = ?", id)[0];
  }

  /** Whether the room keeps messages from before number [id]. */
  private chatBefore(id: number | undefined): boolean {
    return id !== undefined && this.ctx.storage.sql.exec("SELECT 1 FROM messages WHERE id < ? LIMIT 1", id).toArray().length > 0;
  }

  /** A page of messages older than number [before], to this device only: the way to read further back than the last ones. */
  private onChatBefore(ws: WebSocket, before: unknown, n: unknown): void {
    if (!Number.isInteger(before)) return;
    const count = Number.isInteger(n) ? clamp(n as number, 1, CHAT_PAGE_MAX) : CHAT_PAGE;
    const found = this.readMessages("SELECT * FROM messages WHERE id < ? ORDER BY id DESC LIMIT ?", before as number, count + 1);
    this.send(ws, { t: "chat.page", before: before as number, msgs: found.slice(0, count).reverse(), more: found.length > count });
  }

  private chatKeepMs(): number {
    return millis(this.env.CHAT_KEEP_MS, CHAT_KEEP_MS);
  }

  /**
   * Lets go of the messages older than the room keeps, and of those beyond the most it keeps. The latest message always
   * stays (the numbers go on from it) unless [all]: the room is being closed.
   */
  private pruneChat(all: boolean): void {
    const now = Date.now();
    if (!all && now - this.prunedAt < millis(this.env.CHAT_PRUNE_MS, CHAT_PRUNE_EVERY_MS)) return;
    this.prunedAt = now;
    const sql = this.ctx.storage.sql;
    const newest = all ? Number.MAX_SAFE_INTEGER : (this.chat.at(-1)?.id ?? 0);
    sql.exec("DELETE FROM messages WHERE at < ? AND id < ?", now - this.chatKeepMs(), newest);
    const most = millis(this.env.CHAT_KEEP_MAX, CHAT_KEEP_MAX);
    const last = this.chat.at(-1)?.id;
    if (last !== undefined) sql.exec("DELETE FROM messages WHERE id <= ?", last - most);
    const first = sql.exec("SELECT MIN(id) AS id FROM messages").one().id as number | null;
    this.chat = this.chat.filter((m) => first !== null && m.id >= first);
  }

  // ------------------------------------------------------------------ notices to devices that are away

  private vapid(): VapidKeys | null {
    const { VAPID_PRIVATE: privateKey, VAPID_PUBLIC: publicKey, VAPID_SUBJECT: subject } = this.env;
    if (!privateKey || !publicKey) return null;
    return { privateKey, publicKey, subject: subject ?? "https://github.com/tranviethungpv/Sapoche" };
  }

  /** Keeps the browser of this member to be told of the chat while it is away. Sent again at every join, so it stays fresh. */
  private async onPushSet(ws: WebSocket, me: Attachment, msg: Extract<ClientMessage, { t: "push.set" }>): Promise<void> {
    if (!this.vapid()) return this.fail(ws, "push_unavailable", "This server sends no notifications");
    const { room, until, preview, lang } = msg;
    const sub = readSubscription(msg.sub, this.env.PUSH_LOCAL === "1");
    if (!sub || typeof room !== "string" || !/^[A-Za-z0-9]{6}$/.test(room)) {
      return this.fail(ws, "bad_message", "push.set needs a subscription of a push service and the code of the room");
    }
    // A room has at most MAX_MEMBERS people; twice that leaves room for those who changed browser
    const kept = await this.pushDevices();
    if (!kept.has(me.id) && kept.size >= MAX_MEMBERS * 2) return this.fail(ws, "push_full", "Too many devices ask for notifications");
    const device: PushDevice = {
      sub,
      room: room.toUpperCase(),
      seen: Date.now(),
      ...(typeof until === "number" && Number.isFinite(until) ? { until } : {}),
      ...(preview === false ? { preview: false as const } : {}),
      ...(typeof lang === "string" && /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(lang) ? { lang } : {}),
    };
    await this.ctx.storage.put(PUSH_PREFIX + me.id, device);
  }

  /** The devices that ask for notices and are still in the room, by public id. Those that left long ago are let go. */
  private async pushDevices(): Promise<Map<string, PushDevice>> {
    const fresh = millis(this.env.PUSH_FRESH_MS, PUSH_FRESH_MS);
    const here = new Set(this.members().map((m) => m.id));
    const now = Date.now();
    const out = new Map<string, PushDevice>();
    const gone: string[] = [];
    for (const [key, device] of await this.ctx.storage.list<PushDevice>({ prefix: PUSH_PREFIX })) {
      const id = key.slice(PUSH_PREFIX.length);
      if (here.has(id) || now - device.seen <= fresh) out.set(id, device);
      else gone.push(key);
    }
    if (gone.length) await this.ctx.storage.delete(gone);
    return out;
  }

  /** A device is in the room until it closes its connection: that is the last time it was seen. */
  private async notePushSeen(ws: WebSocket): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return;
    const device = await this.ctx.storage.get<PushDevice>(PUSH_PREFIX + att.id);
    if (device) await this.ctx.storage.put(PUSH_PREFIX + att.id, { ...device, seen: Date.now() });
  }

  /**
   * Tells the devices that asked for notices what [by] did, each in the way [kindFor] says (null: not at all). A
   * device with the room open decides for itself whether to show it, so a device that is connected is told as well.
   */
  private async pushNotice(
    by: { id: string; name: string },
    text: string | undefined,
    kindFor: (id: string) => PushKind | null,
    e?: string,
    sealed?: { pv?: string; author: string },
  ): Promise<void> {
    const vapid = this.vapid();
    if (!vapid) return;
    const now = Date.now();
    const dead: string[] = [];
    const preview = text === undefined ? undefined : Array.from(text).slice(0, PUSH_PREVIEW_CHARS).join("");
    await Promise.all(
      [...(await this.pushDevices())].map(async ([id, device]) => {
        const k = id === by.id ? null : kindFor(id);
        if (!k || (device.until ?? 0) > now) return;
        const notice = {
          k,
          room: device.room,
          ...(this.s.name ? { rn: this.s.name } : {}),
          name: by.name,
          // A sealed room has no words to show: the preview goes as it was sealed, for the browser to open
          // [by] is who wrote the message the preview is of, which it was sealed for
          ...(device.preview === false ? {} : preview !== undefined ? { text: preview } : sealed?.pv ? { pv: sealed.pv, by: sealed.author } : {}),
          ...(e ? { e } : {}),
          ...(device.lang ? { l: device.lang } : {}),
        };
        // These mean the browser is gone or does not take this server's signature: it will never work again
        if ([401, 403, 404, 410].includes(await sendWebPush(device.sub, notice, vapid))) dead.push(PUSH_PREFIX + id);
      }),
    );
    if (dead.length) await this.ctx.storage.delete(dead);
  }

  /** Notes how far this member has got in the chat and tells everybody, when it is further than before. */
  private async onChatReceipt(me: Attachment, delivered: unknown, read: unknown): Promise<void> {
    const last = this.chat.at(-1)?.id ?? 0;
    const upTo = (value: unknown) => (Number.isInteger(value) ? clamp(value as number, 0, last) : 0);
    const before = this.receipts[me.id] ?? { d: 0, r: 0 };
    const r = Math.max(before.r, upTo(read));
    const d = Math.max(before.d, upTo(delivered), r);
    if (d === before.d && r === before.r) return;
    this.receipts[me.id] = { d, r };
    this.pruneReceipts();
    await this.ctx.storage.put(RECEIPTS_KEY, this.receipts);
    this.broadcast({ t: "chat.receipts", receipts: this.receipts });
  }

  /** Receipts are kept for those who are here or wrote a message that is still kept, so they cannot pile up over the days. */
  private pruneReceipts(): void {
    const known = new Set([...this.members().map((m) => m.id), ...this.chat.map((m) => m.by)]);
    for (const id of Object.keys(this.receipts)) if (!known.has(id)) delete this.receipts[id];
  }

  /** Passes a reaction on to everybody else; it is not kept. What is neither a known name nor an emoji is ignored. */
  private onReact(me: Attachment, e: unknown, n: unknown): void {
    if (typeof e !== "string" || !(KNOWN_REACTIONS.has(e) || isEmoji(e))) return;
    const count = Number.isInteger(n) ? clamp(n as number, 1, MAX_REACTION_COUNT) : 1;
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att && att.clientId !== me.clientId) this.send(ws, { t: "react", by: me.id, e, n: count });
    }
  }

  /** Sets, or with null takes away, the picture of the device that sent it. */
  private async onAvatarSet(me: Attachment, data: unknown): Promise<void> {
    if (data !== null && (typeof data !== "string" || data.length > MAX_AVATAR_CHARS || !/^[A-Za-z0-9+/=]+$/.test(data))) return;
    let av: string | undefined;
    if (data === null) {
      await this.ctx.storage.delete(AVATAR_PREFIX + me.id);
    } else {
      await this.ctx.storage.put(AVATAR_PREFIX + me.id, data);
      av = await fingerprint(data);
    }
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att?.clientId === me.clientId) ws.serializeAttachment({ ...att, av } satisfies Attachment);
    }
    this.broadcastMembers();
  }

  private async onAvatarGet(ws: WebSocket, id: unknown): Promise<void> {
    if (typeof id !== "string") return;
    if (id === BACKGROUND_ID) {
      const picture = await this.ctx.storage.get<string>(BACKGROUND_KEY);
      if (picture === undefined || !this.s.bg) return this.send(ws, { t: "avatar", id });
      return this.send(ws, { t: "avatar", id, av: this.s.bg, data: picture });
    }
    const data = await this.ctx.storage.get<string>(AVATAR_PREFIX + id);
    const owner = this.members().find((m) => m.id === id);
    if (data === undefined || !owner?.av) return this.send(ws, { t: "avatar", id });
    this.send(ws, { t: "avatar", id, av: owner.av, data });
  }

  private async onSolo(me: Attachment, on: boolean): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att?.clientId === me.clientId) ws.serializeAttachment({ ...att, solo: on } satisfies Attachment);
    }
    this.broadcastMembers();
    // A device that stopped following can no longer be the one the barrier waits for
    await this.maybeStart();
  }

  /** The device is leaving on purpose. An owner hands the room to whoever has been here longest. */
  private async onBye(ws: WebSocket, me: Attachment): Promise<void> {
    await this.ctx.storage.delete(PUSH_PREFIX + me.id); // leaving on purpose ends the notices too
    ws.close(1000, "left"); // the socket no longer counts as a member from here on
    if (this.s.ownerId === me.id) {
      // Somebody who is really here: a device gone quiet (away) only gets the room when nobody else is left
      const limit = Number(this.env.STALE_MS) || AWAY_AFTER_MS;
      const away = (att: Attachment) => (Date.now() - att.lastSeen > limit ? 1 : 0);
      const successor = this.ctx
        .getWebSockets()
        .filter((other) => other.readyState === WebSocket.OPEN)
        .map((other) => other.deserializeAttachment() as Attachment | null)
        .filter((att): att is Attachment => att !== null && att.clientId !== me.clientId)
        .sort((x, y) => away(x) - away(y) || (x.joinedAt ?? 0) - (y.joinedAt ?? 0))[0];
      if (successor) this.s.ownerId = successor.id;
      else delete this.s.ownerId;
      await this.save();
      this.broadcastState();
    }
    await this.onMembersChanged();
  }

  private async onKick(ws: WebSocket, me: Attachment, id: unknown): Promise<void> {
    if (me.id !== this.s.ownerId) return this.fail(ws, "forbidden", "Only the room's owner can do that");
    if (typeof id !== "string" || id === me.id) return;
    await this.ctx.storage.delete(PUSH_PREFIX + id);
    for (const other of this.ctx.getWebSockets()) {
      const att = other.deserializeAttachment() as Attachment | null;
      if (att?.id !== id) continue;
      this.send(other, { t: "error", code: "removed", message: "The owner removed you from the room" });
      other.close(4001, "removed by the owner");
    }
    await this.onMembersChanged();
  }

  private async onRoomName(name: unknown): Promise<void> {
    const clean = typeof name === "string" ? name.trim().slice(0, MAX_ROOM_NAME) : "";
    if (clean === (this.s.name ?? "")) return;
    if (clean) this.s.name = clean;
    else delete this.s.name;
    await this.save();
    this.broadcastState();
  }

  /** A theme with, if the message says so, the picture behind the chat: a string sets it, null takes it away, absent leaves it. */
  private async onRoomTheme(theme: unknown, bg: unknown): Promise<void> {
    if (typeof theme !== "string" || !THEME_NAME.test(theme)) return;
    if (bg !== undefined && bg !== null && (typeof bg !== "string" || bg.length > MAX_BACKGROUND_CHARS || !BASE64.test(bg))) return;
    let changed = false;
    const clean = theme === "default" ? undefined : theme;
    if (clean !== this.s.theme) {
      if (clean) this.s.theme = clean;
      else delete this.s.theme;
      changed = true;
    }
    if (bg === null && this.s.bg) {
      delete this.s.bg;
      await this.ctx.storage.delete(BACKGROUND_KEY);
      changed = true;
    } else if (typeof bg === "string") {
      const fp = await fingerprint(bg);
      if (fp !== this.s.bg) {
        await this.ctx.storage.put(BACKGROUND_KEY, bg);
        this.s.bg = fp;
        changed = true;
      }
    }
    if (!changed) return;
    await this.save();
    this.broadcastState();
  }

  private async onRoomSettings(ws: WebSocket, me: Attachment, guestControl: GuestControl): Promise<void> {
    if (me.id !== this.s.ownerId) return this.fail(ws, "forbidden", "Only the room's owner can do that");
    if (guestControl !== "all" && guestControl !== "add") return;
    if (guestControl === this.s.guestControl) return;
    this.s.guestControl = guestControl;
    await this.save();
    this.broadcastState();
  }

  /** The owner is here, or guests are free to do everything, or this is the owner. */
  private canControl(id: string): boolean {
    if (this.s.guestControl === "all" || id === this.s.ownerId) return true;
    return !this.members().some((m) => m.owner && !m.away);
  }

  /** What the app shows about a room before joining it. Reads only: it never creates anything. */
  private info() {
    const item = this.s.queue[this.s.index];
    return {
      exists: this.created,
      name: this.s.name ?? null,
      members: this.members().filter((m) => !m.away).length,
      playing: this.s.phase === "playing",
      title: item?.title ?? null,
      ...(this.s.enc ? { enc: true } : {}),
    };
  }

  /** Sends one device the current state again, plus the prepare it may have missed. */
  private onResync(ws: WebSocket, me: Attachment): void {
    this.send(ws, this.stateMessage(me.id));
    if (this.s.phase === "preparing") this.send(ws, this.prepareMessage());
  }

  /** Closes devices whose connection died silently, and announces devices that went quiet. */
  private async sweep(): Promise<void> {
    const now = Date.now();
    let dropped = false;
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att && now - att.lastSeen > millis(this.env.DROP_MS, DROP_AFTER_MS)) {
        try {
          ws.close(1001, "no signal from this device");
        } catch {
          // Already closing
        }
        dropped = true;
      }
    }
    if (dropped) await this.onMembersChanged();
    else this.broadcastMembers();
  }

  /** Broadcasts the member list when who is here, away or solo changed since the last time. */
  private broadcastMembers(): void {
    const members = this.members();
    const key = members.map((m) => `${m.id}:${m.name}:${m.ready}:${m.solo}:${m.away}:${m.owner}:${m.av ?? ""}`).join("|");
    if (key === this.membersKey) return;
    this.membersKey = key;
    this.broadcast({ t: "members", members });
  }

  // ------------------------------------------------------------------ queue

  private async onQueueAdd(me: Attachment, msg: Extract<ClientMessage, { t: "queue.add" }>): Promise<void> {
    return this.addTracks(me, [msg], msg.next === true, false);
  }

  private async onQueueAddMany(me: Attachment, msg: Extract<ClientMessage, { t: "queue.addMany" }>): Promise<void> {
    if (!Array.isArray(msg.tracks)) return this.failAll(me, "bad_message", "queue.addMany needs tracks");
    return this.addTracks(me, msg.tracks.slice(0, MAX_ADD_MANY), msg.next === true, msg.auto === true);
  }

  /**
   * Puts valid tracks on the queue in the given order, at the end or right after the current item. A member's songs go
   * before what autoplay put at the end; [auto] songs are those autoplay found, taken only while the room is idle
   * (it asks only then, so anything else is an answer to a question the room has moved past).
   */
  private async addTracks(me: Attachment, tracks: TrackInput[], playNext: boolean, auto: boolean): Promise<void> {
    if (auto) {
      if (this.s.phase !== "idle" || !this.s.autoplay) return;
      this.dropAutoplayed();
      playNext = false;
    }
    const items: QueueItem[] = [];
    for (const track of tracks) {
      if (!VIDEO_ID.test(track?.videoId ?? "")) {
        if (tracks.length === 1) return this.failAll(me, "bad_video", "Invalid videoId");
        continue;
      }
      if (this.s.queue.length + items.length >= MAX_QUEUE) {
        this.failAll(me, "queue_full", "Queue is full");
        break;
      }
      items.push({ id: crypto.randomUUID(), ...cleanTrack(track), addedBy: me.id, ...(auto ? { auto: true as const } : {}) });
    }
    if (items.length === 0) return;

    // "Play next" only makes sense while something is playing; otherwise the new items simply go last, but
    // not behind what autoplay added
    const playing = this.s.phase !== "idle";
    const at = playNext && playing ? this.s.index + 1 : auto || !playing ? this.s.queue.length : this.autoplayedFrom();
    this.s.queue.splice(at, 0, ...items);
    // A song a member picks that autoplay had lined up is the member's now, and is not played twice
    if (!auto && playing && this.s.queue.some((q) => q.auto)) {
      const picked = new Set(items.map((item) => item.videoId));
      const current = this.s.queue[this.s.index];
      this.s.queue = this.s.queue.filter((q) => !(q.auto && q !== current && picked.has(q.videoId)));
    }
    // With shuffle on, songs added at the end are mixed in among those to come instead of waiting behind them
    if (this.s.shuffle && playing && !playNext && !auto) {
      const first = this.s.index + 1;
      this.s.queue.splice(at, items.length);
      items.forEach((item, i) => this.s.queue.splice(randomBelow(at - first + i + 1) + first, 0, item));
    }

    if (this.s.phase === "idle") {
      await this.begin(at, 0);
    } else {
      await this.save();
      this.broadcastState();
    }
  }

  /** Where what autoplay added begins among the songs still to come; the length of the queue when there is none. */
  private autoplayedFrom(): number {
    const at = this.s.queue.findIndex((q, i) => i > this.s.index && q.auto);
    return at < 0 ? this.s.queue.length : at;
  }

  /**
   * Takes what autoplay added out of the queue, so that it does not stay in a list the members made: the room is done
   * with it. The index follows the queue; with nothing playing it points at the last song, as it does after the end.
   */
  private dropAutoplayed(): void {
    if (!this.s.queue.some((q) => q.auto)) return;
    const currentId = this.s.queue[this.s.index]?.id;
    this.s.queue = this.s.queue.filter((q) => !q.auto);
    const kept = this.s.queue.findIndex((q) => q.id === currentId);
    this.s.index = kept >= 0 ? kept : Math.max(0, this.s.queue.length - 1);
  }

  private async onQueueRemove(id: string): Promise<void> {
    const at = this.s.queue.findIndex((q) => q.id === id);
    if (at < 0) return;
    const removingCurrent = at === this.s.index && this.s.phase !== "idle";
    this.s.queue.splice(at, 1);

    if (removingCurrent) {
      if (this.s.index < this.s.queue.length) return this.begin(this.s.index, 0);
      return this.goIdle();
    }
    if (at < this.s.index) this.s.index--;
    await this.save();
    this.broadcastState();
  }

  private async onQueueSwap(me: Attachment, msg: Extract<ClientMessage, { t: "queue.swap" }>): Promise<void> {
    const at = this.s.queue.findIndex((q) => q.id === msg.id);
    if (at < 0) return;
    if (!VIDEO_ID.test(msg.track?.videoId ?? "")) return this.failAll(me, "bad_video", "Invalid videoId");
    const item = this.s.queue[at];
    if (item.videoId === msg.track.videoId) return;
    Object.assign(item, cleanTrack(msg.track));

    if (at === this.s.index && this.s.phase !== "idle") {
      // The same moment of the song, from the other release
      const positionMs = clamp(this.currentPositionMs(), 0, item.durMs || Number.MAX_SAFE_INTEGER);
      return this.begin(at, positionMs, me.id);
    }
    await this.save();
    this.broadcastState();
  }

  private async onQueueClear(): Promise<void> {
    if (this.s.queue.length === 0) return;
    this.s.queue = [];
    return this.goIdle();
  }

  /**
   * Mixes up what is still to come, so the song playing carries on. When nothing is playing the
   * whole queue is mixed and played from the top: the way to hear a finished list again in a new order.
   */
  private async onQueueShuffle(by: string): Promise<void> {
    if (this.s.queue.length < 2) return;
    if (this.s.phase === "idle") {
      shuffleInPlace(this.s.queue, 0);
      return this.begin(0, 0, by);
    }
    shuffleInPlace(this.s.queue, this.s.index + 1, this.autoplayedFrom());
    await this.save();
    this.broadcastState();
  }

  /**
   * Shuffle as a mode, as Apple Music has it. On: the order the queue has is remembered and what is still to come is
   * mixed; songs added later are mixed in. Off: what is still to come goes back to the remembered order, and songs that
   * were added meanwhile follow it.
   */
  private async onShuffle(on: unknown): Promise<void> {
    if (typeof on !== "boolean" || on === this.s.shuffle) return;
    this.s.shuffle = on;
    if (on) {
      this.s.shuffleOrder = this.s.queue.map((q) => q.id);
      if (this.s.phase !== "idle") shuffleInPlace(this.s.queue, this.s.index + 1, this.autoplayedFrom());
    } else {
      const order = new Map((this.s.shuffleOrder ?? []).map((id, i) => [id, i]));
      delete this.s.shuffleOrder;
      const first = this.s.phase === "idle" ? 0 : this.s.index + 1;
      const rank = (q: QueueItem) => order.get(q.id) ?? Number.MAX_SAFE_INTEGER;
      // The sort is stable, so songs that were not there when shuffle went on keep their order, at the end; what
      // autoplay added stays behind them all
      const rest = [
        ...this.s.queue.slice(first).filter((q) => !q.auto).sort((a, b) => rank(a) - rank(b)),
        ...this.s.queue.slice(first).filter((q) => q.auto),
      ];
      this.s.queue.splice(first, rest.length, ...rest);
    }
    await this.save();
    this.broadcastState();
  }

  private async onJump(id: string, by: string): Promise<void> {
    const at = this.s.queue.findIndex((q) => q.id === id);
    if (at >= 0) return this.begin(at, 0, by);
  }

  private async onQueueMove(id: string, toIndex: number): Promise<void> {
    const from = this.s.queue.findIndex((q) => q.id === id);
    if (from < 0 || !Number.isInteger(toIndex)) return;
    const to = clamp(toIndex, 0, this.s.queue.length - 1);
    const currentId = this.s.queue[this.s.index]?.id;
    const [item] = this.s.queue.splice(from, 1);
    // A song a member puts in its place is theirs now, not autoplay's
    delete item.auto;
    this.s.queue.splice(to, 0, item);
    if (currentId) this.s.index = Math.max(0, this.s.queue.findIndex((q) => q.id === currentId));
    await this.save();
    this.broadcastState();
  }

  // ------------------------------------------------------------------ transport

  /** Start preparing an item: every device resolves and buffers it, then the barrier releases the start. */
  private async begin(index: number, seekToMs: number, by?: string): Promise<void> {
    this.s.index = index;
    this.s.epoch++;
    this.s.phase = "preparing";
    this.s.positionMs = seekToMs;
    this.s.startedAt = 0;
    this.s.readyIds = [];
    this.s.failedIds = [];
    delete this.s.alarms.end;
    await this.setAlarm("barrier", Date.now() + BARRIER_TIMEOUT_MS);
    this.broadcastState();
    this.broadcast(this.prepareMessage(by));
    await this.maybeStart();
  }

  private async onReady(id: string, epoch: number): Promise<void> {
    if (this.s.phase !== "preparing" || epoch !== this.s.epoch) return;
    if (!this.s.readyIds.includes(id)) this.s.readyIds.push(id);
    await this.save();
    this.broadcastMembers();
    await this.maybeStart();
  }

  /** A device could not load the item. It counts as answered, so it never holds the others back. */
  private async onResolveFailed(id: string, epoch: number): Promise<void> {
    if (this.s.phase !== "preparing" || epoch !== this.s.epoch) return;
    if (!this.s.failedIds.includes(id)) this.s.failedIds.push(id);
    return this.onReady(id, epoch);
  }

  /** Releases the barrier once every connected device is ready. */
  private async maybeStart(): Promise<void> {
    if (this.s.phase !== "preparing") return;
    // Devices that stopped answering, or that listen on their own, must not hold the room back
    const members = this.members().filter((m) => !m.away && !m.solo);
    if (members.length === 0 || !members.every((m) => m.ready)) return;

    // Nobody can play this item: skip it instead of running a silent clock until it "ends"
    if (members.every((m) => this.s.failedIds.includes(m.id))) {
      const item = this.s.queue[this.s.index];
      this.broadcast({ t: "error", code: "unplayable", message: `Nobody could load: ${item?.title ?? "item"}` });
      // No autoplay after a song nobody could play: if its successors were broken too it would never end
      return this.onNext(undefined, false);
    }
    await this.startPlayback();
  }

  private async startPlayback(by?: string): Promise<void> {
    const startAt = Date.now() + this.leadMs();
    this.s.phase = "playing";
    this.s.startedAt = startAt - this.s.positionMs;
    this.s.readyIds = [];
    this.s.failedIds = [];
    delete this.s.alarms.barrier;
    await this.scheduleEnd();
    this.broadcast({ t: "start", epoch: this.s.epoch, startAt, positionMs: this.s.positionMs, by });
  }

  private async onPlay(by: string): Promise<void> {
    if (this.s.phase === "paused") {
      this.s.epoch++;
      return this.startPlayback(by);
    }
    if (this.s.phase === "idle" && this.s.queue[this.s.index]) {
      // After the last song, play means "again": from the top of the list, not just the last song
      const atEnd = this.s.index >= this.s.queue.length - 1;
      return this.begin(atEnd ? 0 : this.s.index, 0, by);
    }
  }

  private async onPause(by: string): Promise<void> {
    if (this.s.phase === "preparing") {
      // Pressed while the song is still loading: hold it there, or it would start behind the person's back
      this.s.phase = "paused";
      this.s.epoch++;
      this.s.readyIds = [];
      this.s.failedIds = [];
      delete this.s.alarms.barrier;
      await this.armAlarm();
      this.broadcastMembers();
      this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs, by });
      return;
    }
    if (this.s.phase !== "playing") return;
    this.s.positionMs = this.currentPositionMs();
    this.s.phase = "paused";
    this.s.epoch++;
    await this.clearAlarm("end");
    this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs, by });
  }

  private async onSeek(positionMs: number, by: string): Promise<void> {
    if (this.s.phase === "idle") return;
    if (typeof positionMs !== "number" || !Number.isFinite(positionMs)) return;
    const item = this.s.queue[this.s.index];
    this.s.positionMs = clamp(positionMs, 0, item?.durMs || Number.MAX_SAFE_INTEGER);
    if (this.s.phase === "preparing") {
      // The song is still loading: the barrier goes on, the start carries the new place, and whoever joins meanwhile
      // prepares there. Devices already loading seek once the start comes, which leaves them the lead time to do it
      await this.save();
      this.broadcastState();
      return;
    }
    this.s.epoch++;
    if (this.s.phase === "playing") return this.startPlayback(by);
    await this.save();
    this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs, by });
  }

  /**
   * [by] is set when a person asked for it; when the queue simply reaches the next item it is left out. When this
   * runs the queue out, autoplay asks for more unless [askForMore] is false.
   */
  private async onNext(by?: string, askForMore = true): Promise<void> {
    if (this.s.phase === "idle") return;
    if (this.s.index + 1 < this.s.queue.length) return this.begin(this.s.index + 1, 0, by);
    // The room has played everything: what autoplay added has served, and the list is the members' again
    const last = this.s.queue[this.s.index];
    this.dropAutoplayed();
    if (this.s.repeat === "all" && this.s.queue.length > 0) return this.begin(0, 0, by);
    await this.goIdle();
    if (askForMore && last) this.askForMoreSongs(last);
  }

  /** The current item played to its end: repeat it, or move on like the next button does. */
  private async onFinished(): Promise<void> {
    if (this.s.repeat === "one" && this.s.queue[this.s.index]) return this.begin(this.s.index, 0);
    return this.onNext();
  }

  private async onAutoplay(on: unknown): Promise<void> {
    if (typeof on !== "boolean" || on === this.s.autoplay) return;
    this.s.autoplay = on;
    // Turned off, what it already added and the room has not got to is no longer wanted
    if (!on) this.s.queue = this.s.queue.filter((q, i) => !q.auto || i <= this.s.index);
    await this.save();
    this.broadcastState();
  }

  /**
   * The queue ran out. The server cannot fetch songs itself (YouTube blocks it), so one device that is here is asked to:
   * the owner's if it is a device following the room, else whoever has been here longest.
   */
  private askForMoreSongs(last: QueueItem): void {
    if (!this.s.autoplay) return;
    const limit = Number(this.env.STALE_MS) || AWAY_AFTER_MS;
    const now = Date.now();
    const rank = (att: Attachment) => (att.solo ? 2 : 0) + (att.id === this.s.ownerId ? 0 : 1);
    const asked = this.ctx
      .getWebSockets()
      .filter((ws) => ws.readyState === WebSocket.OPEN)
      .map((ws) => ({ ws, att: ws.deserializeAttachment() as Attachment | null }))
      .filter((c): c is { ws: WebSocket; att: Attachment } => c.att !== null && now - c.att.lastSeen <= limit)
      .sort((x, y) => rank(x.att) - rank(y.att) || (x.att.joinedAt ?? 0) - (y.att.joinedAt ?? 0))[0];
    if (asked) this.send(asked.ws, { t: "autoplay.fill", epoch: this.s.epoch, videoId: last.videoId, title: last.title });
  }

  private async onRepeat(mode: Repeat): Promise<void> {
    if (mode !== "off" && mode !== "all" && mode !== "one") return;
    if (mode === this.s.repeat) return;
    this.s.repeat = mode;
    await this.save();
    this.broadcastState();
  }

  private async onPrev(by: string): Promise<void> {
    if (this.s.phase === "idle") return;
    // Like most players: restart the current item unless we are right at its start
    if (this.currentPositionMs() > 3000) return this.begin(this.s.index, 0, by);
    return this.begin(Math.max(0, this.s.index - 1), 0, by);
  }

  /** A device reports the item finished. The first report for the current epoch advances the queue. */
  private async onEnded(epoch: number): Promise<void> {
    if (epoch !== this.s.epoch || this.s.phase !== "playing") return;
    const item = this.s.queue[this.s.index];
    // Ignore reports that arrive implausibly early
    if (item && item.durMs > 0 && this.currentPositionMs() < item.durMs - 5000) return;
    return this.onFinished();
  }

  /**
   * A device already moved on to the next item on its own, so devices that preloaded it need no
   * barrier and no gap. The first plausible report fixes the new start time for everyone.
   */
  private async onAdvanced(epoch: number, itemId: string, startedAt: number): Promise<void> {
    if (this.s.phase !== "playing" || epoch !== this.s.epoch) return;
    if (this.s.repeat === "one") return; // the same item is played again, through a barrier
    const next = this.s.queue[this.s.index + 1];
    if (!next || next.id !== itemId) return;
    if (typeof startedAt !== "number" || !Number.isFinite(startedAt)) return;

    const now = Date.now();
    if (startedAt > now + ADVANCE_FUTURE_SLACK_MS || startedAt < now - ADVANCE_MAX_AGE_MS) return;
    // Only believe it when the current item is close to its end by the room's own clock
    const current = this.s.queue[this.s.index];
    if (current && current.durMs > 0 && now - this.s.startedAt < current.durMs - ADVANCE_EARLY_LIMIT_MS) return;

    this.s.index++;
    this.s.epoch++;
    this.s.positionMs = 0;
    this.s.startedAt = startedAt;
    await this.scheduleEnd();
    this.broadcast({ t: "advance", epoch: this.s.epoch, index: this.s.index, startedAt });
  }

  private async goIdle(): Promise<void> {
    this.s.phase = "idle";
    this.s.epoch++;
    this.s.positionMs = 0;
    this.s.readyIds = [];
    this.s.failedIds = [];
    this.s.index = Math.min(this.s.index, Math.max(0, this.s.queue.length - 1));
    delete this.s.alarms.barrier;
    await this.clearAlarm("end");
    this.broadcastState();
  }

  // ------------------------------------------------------------------ alarm

  async alarm(): Promise<void> {
    const now = Date.now();
    const due = (Object.entries(this.s.alarms) as [AlarmKind, number][]).filter(([, at]) => at <= now).map(([kind]) => kind);
    for (const kind of due) delete this.s.alarms[kind];

    // Dead connections first, so the jobs below see who is really here
    if (due.includes("sweep")) await this.sweep();
    if (due.includes("barrier")) {
      // Start without the devices that did not answer in time; they catch up when they finish loading
      if (this.s.phase === "preparing" && this.members().length > 0) await this.startPlayback();
    }
    if (due.includes("end") && this.s.phase === "playing") await this.onFinished();
    if (due.includes("gc") && this.members().length === 0) {
      this.pruneChat(true);
      const last = this.chat.at(-1);
      if (last) {
        // The songs and the settings are over, but the room itself stays for as long as its chat does
        const { name, enc, theme, bg } = this.s;
        this.s = defaultState();
        if (name) this.s.name = name;
        if (theme) this.s.theme = theme;
        if (bg) this.s.bg = bg;
        if (enc) this.s.enc = enc;
        this.s.alarms.gc = last.at + this.chatKeepMs();
        await this.armAlarm();
        return;
      }
      this.s = defaultState();
      this.chat = [];
      this.receipts = {};
      this.created = false;
      await this.ctx.storage.deleteAll();
      // Whether the table went with everything else or not, the next room of this code starts with an empty one
      await this.openChat();
      return;
    }
    // Keep looking for dead connections for as long as someone is here; another job firing does not push the next look back
    if (this.members().length > 0 && !this.s.alarms.sweep) this.s.alarms.sweep = Date.now() + this.dropCheckMs();
    await this.armAlarm();
  }

  private async scheduleEnd(): Promise<void> {
    const item = this.s.queue[this.s.index];
    if (!item || item.durMs <= 0) return this.clearAlarm("end");
    await this.setAlarm("end", this.s.startedAt + item.durMs + END_GRACE_MS);
  }

  private async setAlarm(kind: AlarmKind, at: number): Promise<void> {
    this.s.alarms[kind] = at;
    await this.armAlarm();
  }

  private async clearAlarm(kind: AlarmKind): Promise<void> {
    delete this.s.alarms[kind];
    await this.armAlarm();
  }

  /** Points the single Durable Object alarm at the earliest pending job, and saves the list of jobs. */
  private async armAlarm(): Promise<void> {
    const at = Math.min(...Object.values(this.s.alarms));
    if (Number.isFinite(at)) await this.ctx.storage.setAlarm(at);
    else await this.ctx.storage.deleteAlarm();
    await this.save();
  }

  private emptyTtlMs(): number {
    return this.s.queue.length > 0
      ? millis(this.env.EMPTY_MS, EMPTY_ROOM_TTL_MS)
      : millis(this.env.EMPTY_BARE_MS, EMPTY_BARE_ROOM_TTL_MS);
  }

  private dropCheckMs(): number {
    return millis(this.env.SWEEP_MS, DROP_CHECK_MS);
  }

  // ------------------------------------------------------------------ helpers

  /** Keeps the round trip a device reports with its pings. */
  private noteRoundTrip(ws: WebSocket, rtt: unknown): void {
    if (typeof rtt !== "number" || !Number.isFinite(rtt)) return;
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return;
    att.rtt = clamp(Math.round(rtt), 0, 10_000);
    ws.serializeAttachment(att);
  }

  /** How far ahead to schedule a start: enough for the slowest device that follows the room, LEAD_MS when one does not say. */
  private leadMs(): number {
    const limit = Number(this.env.STALE_MS) || AWAY_AFTER_MS;
    const now = Date.now();
    const following = this.ctx
      .getWebSockets()
      .filter((ws) => ws.readyState === WebSocket.OPEN)
      .map((ws) => ws.deserializeAttachment() as Attachment | null)
      .filter((att): att is Attachment => att !== null && !att.solo && now - att.lastSeen <= limit);
    if (following.length === 0 || following.some((att) => att.rtt === undefined)) return LEAD_MS;
    return clamp(Math.max(...following.map((att) => att.rtt ?? 0)) + LEAD_MARGIN_MS, MIN_LEAD_MS, LEAD_MS);
  }

  /** A next or previous names the item it was pressed on; one sent by an older app names none and always counts. */
  private pressedOnCurrent(from: unknown): boolean {
    return typeof from !== "string" || from === this.s.queue[this.s.index]?.id;
  }

  /**
   * Rooms saved before members had public ids kept each device's secret id as the owner and as who added a song.
   * Hashing such an id gives exactly the public id that device has now, so its owner and its songs stay its own.
   */
  private async migrateIds(): Promise<void> {
    const legacy = (value: string | undefined): value is string => value !== undefined && !PUBLIC_ID.test(value);
    if (legacy(this.s.ownerId)) this.s.ownerId = await publicId(this.s.ownerId);
    for (const item of this.s.queue) {
      if (legacy(item.addedBy)) item.addedBy = await publicId(item.addedBy);
    }
    const migrate = (ids: string[]) => Promise.all(ids.map((value) => (legacy(value) ? publicId(value) : value)));
    this.s.readyIds = await migrate(this.s.readyIds);
    this.s.failedIds = await migrate(this.s.failedIds);
  }

  private currentPositionMs(): number {
    if (this.s.phase === "playing") return Math.max(0, Date.now() - this.s.startedAt);
    return this.s.positionMs;
  }

  private members(): Member[] {
    const limit = Number(this.env.STALE_MS) || AWAY_AFTER_MS;
    const now = Date.now();
    const out: Member[] = [];
    for (const ws of this.ctx.getWebSockets()) {
      // A socket we just closed can linger in the list for a moment
      if (ws.readyState !== WebSocket.OPEN) continue;
      const att = ws.deserializeAttachment() as Attachment | null;
      if (!att) continue;
      out.push({
        id: att.id,
        name: att.name,
        ready: this.s.readyIds.includes(att.id),
        solo: att.solo === true,
        away: now - att.lastSeen > limit,
        owner: att.id === this.s.ownerId,
        ...(att.av ? { av: att.av } : {}),
      });
    }
    return out;
  }

  /** Record that a socket just spoke. Attachments live with the socket, so this costs no storage write. */
  private touch(ws: WebSocket): void {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return;
    att.lastSeen = Date.now();
    ws.serializeAttachment(att);
  }

  private publicState(): PublicState {
    const { readyIds: _r, failedIds: _f, alarms: _a, shuffleOrder: _o, ...rest } = this.s;
    return { ...rest, theme: rest.theme ?? "default" };
  }

  private stateMessage(you: string): ServerMessage {
    return {
      t: "state",
      serverNow: Date.now(),
      you,
      protocol: PROTOCOL_VERSION,
      state: this.publicState(),
      members: this.members(),
    };
  }

  private prepareMessage(by?: string): ServerMessage {
    return {
      t: "prepare",
      epoch: this.s.epoch,
      index: this.s.index,
      item: this.s.queue[this.s.index],
      seekToMs: this.s.positionMs,
      by,
    };
  }

  private broadcastState(): void {
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att) this.send(ws, this.stateMessage(att.id));
    }
  }

  private broadcast(msg: ServerMessage): void {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.deserializeAttachment()) this.send(ws, msg);
    }
  }

  private send(ws: WebSocket, msg: ServerMessage): void {
    try {
      ws.send(JSON.stringify(msg));
    } catch {
      // The socket is closing; the close handler will clean up
    }
  }

  private fail(ws: WebSocket, code: string, message: string): void {
    this.send(ws, { t: "error", code, message });
  }

  /** Error to whoever caused it, found by client id. */
  private failAll(me: Attachment, code: string, message: string): void {
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att?.clientId === me.clientId) this.fail(ws, code, message);
    }
  }

  private async save(): Promise<void> {
    await this.ctx.storage.put("state", this.s);
  }

  /** Token bucket: up to MAX_MESSAGES_PER_SECOND messages per second per socket. */
  private allow(ws: WebSocket): boolean {
    const now = Date.now();
    const bucket = this.buckets.get(ws) ?? { tokens: MAX_MESSAGES_PER_SECOND, last: now };
    bucket.tokens = Math.min(
      MAX_MESSAGES_PER_SECOND,
      bucket.tokens + ((now - bucket.last) / 1000) * MAX_MESSAGES_PER_SECOND,
    );
    bucket.last = now;
    this.buckets.set(ws, bucket);
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }
}

/** What a public id looks like: 16 hexadecimal digits. The app's own secret ids are UUIDs, which never do. */
const PUBLIC_ID = /^[0-9a-f]{16}$/;

/**
 * The id a device is known by in the room: the start of the SHA-256 of its secret client id. Everybody can see it, and
 * nobody can work the secret back from it, so knowing it does not let anyone join as that device or as the owner.
 */
async function publicId(clientId: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`sapoche-member:${clientId}`));
  return [...new Uint8Array(digest).slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** A short fingerprint of a picture, so that clients know whether the one they hold is the current one. */
async function fingerprint(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest).slice(0, 4)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/** What a reply carries of the message it answers. */
function quote(m: ChatMessage): ChatQuote {
  const chars = Array.from(m.text);
  const text = chars.length > QUOTE_CHARS ? `${chars.slice(0, QUOTE_CHARS).join("").trimEnd()}…` : m.text;
  return { id: m.id, by: m.by, name: m.name, text };
}

/** A whole number from 0 up to, not including, [n]. */
function randomBelow(n: number): number {
  return Math.floor((crypto.getRandomValues(new Uint32Array(1))[0] / 2 ** 32) * n);
}

/** Fisher-Yates over the items from [from] up to, not including, [to] (the end by default), with an unbiased random source. */
function shuffleInPlace<T>(items: T[], from: number, to = items.length): void {
  for (let i = to - 1; i > from; i--) {
    const range = i - from + 1;
    const j = from + Math.floor((crypto.getRandomValues(new Uint32Array(1))[0] / 2 ** 32) * range);
    [items[i], items[j]] = [items[j], items[i]];
  }
}
