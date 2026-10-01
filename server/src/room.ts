import { DurableObject } from "cloudflare:workers";
import { PROTOCOL_VERSION } from "./protocol";
import type {
  AlarmKind,
  ClientMessage,
  GuestControl,
  Member,
  PublicState,
  QueueItem,
  Repeat,
  RoomState,
  ServerMessage,
  TrackInput,
} from "./protocol";

/** How far in the future a start is scheduled, so every device has time to receive and arm it. */
const LEAD_MS = 1500;
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
const MAX_QUEUE = 200;
const MAX_MESSAGE_CHARS = 32_768;
/** Songs accepted from one queue.addMany message. */
const MAX_ADD_MANY = 100;
const MAX_MESSAGES_PER_SECOND = 20;
const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;

interface Attachment {
  clientId: string;
  name: string;
  /** Last time this socket sent anything; clients ping every 30 seconds. */
  lastSeen: number;
  /** Listening on their own, so the room does not wait for or move this device. */
  solo: boolean;
  /** When this device joined; the longest present member takes over when the owner leaves. */
  joinedAt?: number;
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
  "room.name",
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

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const saved = await ctx.storage.get<RoomState & { alarm?: string }>("state");
      if (!saved) return;
      // Fields added after a room was saved get their defaults
      const { alarm, ...rest } = saved;
      this.s = { ...defaultState(), ...rest };
      this.created = true;
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
    if (typeof raw !== "string" || raw.length > MAX_MESSAGE_CHARS) {
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

    if (msg.t === "ping") {
      if (typeof msg.c0 !== "number") return this.fail(ws, "bad_message", "ping needs c0");
      return this.send(ws, { t: "pong", c0: msg.c0, s1: Date.now() });
    }
    if (msg.t === "join") return this.onJoin(ws, msg);

    const me = ws.deserializeAttachment() as Attachment | null;
    if (!me) return this.fail(ws, "not_joined", "Send join first");
    if (CONTROL_MESSAGES.has(msg.t) && !this.canControl(me.clientId)) {
      return this.fail(ws, "forbidden", "Only the room's owner can do that");
    }

    switch (msg.t) {
      case "queue.add": return this.onQueueAdd(me, msg);
      case "queue.addMany": return this.onQueueAddMany(me, msg);
      case "queue.remove": return this.onQueueRemove(msg.id);
      case "queue.swap": return this.onQueueSwap(me, msg);
      case "queue.clear": return this.onQueueClear();
      case "queue.shuffle": return this.onQueueShuffle(me.clientId);
      case "jump": return this.onJump(msg.id, me.clientId);
      case "queue.move": return this.onQueueMove(msg.id, msg.toIndex);
      case "play": return this.onPlay(me.clientId);
      case "pause": return this.onPause(me.clientId);
      case "seek": return this.onSeek(msg.positionMs, me.clientId);
      case "next": return this.onNext(me.clientId);
      case "prev": return this.onPrev(me.clientId);
      case "repeat": return this.onRepeat(msg.mode);
      case "solo": return this.onSolo(me, msg.on === true);
      case "bye": return this.onBye(ws, me);
      case "kick": return this.onKick(ws, me, msg.id);
      case "room.name": return this.onRoomName(msg.name);
      case "room.settings": return this.onRoomSettings(ws, me, msg.guestControl);
      case "resync": return this.onResync(ws, me);
      case "ready": return this.onReady(me.clientId, msg.epoch);
      case "resolveFailed": return this.onResolveFailed(me.clientId, msg.epoch);
      case "ended": return this.onEnded(msg.epoch);
      case "advanced": return this.onAdvanced(msg.epoch, msg.itemId, msg.startedAt);
      case "report": return; // diagnostics only for now
      default: return this.fail(ws, "unknown_type", `Unknown message type`);
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    ws.close(1000, "closed");
    await this.onMembersChanged();
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    ws.close(1011, "error");
    await this.onMembersChanged();
  }

  private async onJoin(ws: WebSocket, msg: Extract<ClientMessage, { t: "join" }>): Promise<void> {
    const clientId = typeof msg.clientId === "string" ? msg.clientId.slice(0, 64) : "";
    const name = typeof msg.name === "string" ? msg.name.trim().slice(0, 32) : "";
    if (!clientId || !name) return this.fail(ws, "bad_message", "join needs clientId and name");

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
    if (this.members().length >= MAX_MEMBERS && !this.members().some((m) => m.id === clientId)) {
      this.fail(ws, "room_full", "The room is full");
      ws.close(1008, "room is full");
      return;
    }

    // A second join on the same socket is a rename: keep the listening mode and the place in line
    const before = ws.deserializeAttachment() as Attachment | null;
    const now = Date.now();
    ws.serializeAttachment(
      { clientId, name, lastSeen: now, solo: before?.solo ?? false, joinedAt: before?.joinedAt ?? now } satisfies Attachment,
    );

    // The first to arrive owns a room that has no owner; the room now exists and someone is in it
    this.created = true;
    const adopted = !this.s.ownerId;
    if (adopted) this.s.ownerId = clientId;
    delete this.s.alarms.gc;
    if (!this.s.alarms.sweep) this.s.alarms.sweep = now + this.dropCheckMs();
    await this.armAlarm();

    if (adopted) this.broadcastState();
    else this.send(ws, this.stateMessage(clientId));
    // A device joining mid-preparation must take part in the barrier
    if (this.s.phase === "preparing") this.send(ws, this.prepareMessage());
    this.broadcastMembers();
  }

  private async onMembersChanged(): Promise<void> {
    const members = this.members();
    if (members.length === 0) {
      // A socket that never joined a room that does not exist is nothing to keep
      if (!this.created) return;
      // Nobody is listening: freeze the position, let go of the ownership and schedule cleanup
      if (this.s.phase === "playing") {
        this.s.positionMs = this.currentPositionMs();
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
    this.broadcastMembers();
    await this.maybeStart(); // the device we were waiting for may be the one that left
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
    ws.close(1000, "left"); // the socket no longer counts as a member from here on
    if (this.s.ownerId === me.clientId) {
      const successor = this.ctx
        .getWebSockets()
        .filter((other) => other.readyState === WebSocket.OPEN)
        .map((other) => other.deserializeAttachment() as Attachment | null)
        .filter((att): att is Attachment => att !== null && att.clientId !== me.clientId)
        .sort((x, y) => (x.joinedAt ?? 0) - (y.joinedAt ?? 0))[0];
      if (successor) this.s.ownerId = successor.clientId;
      else delete this.s.ownerId;
      await this.save();
      this.broadcastState();
    }
    await this.onMembersChanged();
  }

  private async onKick(ws: WebSocket, me: Attachment, id: unknown): Promise<void> {
    if (me.clientId !== this.s.ownerId) return this.fail(ws, "forbidden", "Only the room's owner can do that");
    if (typeof id !== "string" || id === me.clientId) return;
    for (const other of this.ctx.getWebSockets()) {
      const att = other.deserializeAttachment() as Attachment | null;
      if (att?.clientId !== id) continue;
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

  private async onRoomSettings(ws: WebSocket, me: Attachment, guestControl: GuestControl): Promise<void> {
    if (me.clientId !== this.s.ownerId) return this.fail(ws, "forbidden", "Only the room's owner can do that");
    if (guestControl !== "all" && guestControl !== "add") return;
    if (guestControl === this.s.guestControl) return;
    this.s.guestControl = guestControl;
    await this.save();
    this.broadcastState();
  }

  /** The owner is here, or guests are free to do everything, or this is the owner. */
  private canControl(clientId: string): boolean {
    if (this.s.guestControl === "all" || clientId === this.s.ownerId) return true;
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
    };
  }

  /** Sends one device the current state again, plus the prepare it may have missed. */
  private onResync(ws: WebSocket, me: Attachment): void {
    this.send(ws, this.stateMessage(me.clientId));
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
    const key = members.map((m) => `${m.id}:${m.name}:${m.ready}:${m.solo}:${m.away}:${m.owner}`).join("|");
    if (key === this.membersKey) return;
    this.membersKey = key;
    this.broadcast({ t: "members", members });
  }

  // ------------------------------------------------------------------ queue

  private async onQueueAdd(me: Attachment, msg: Extract<ClientMessage, { t: "queue.add" }>): Promise<void> {
    return this.addTracks(me, [msg], msg.next === true);
  }

  private async onQueueAddMany(me: Attachment, msg: Extract<ClientMessage, { t: "queue.addMany" }>): Promise<void> {
    if (!Array.isArray(msg.tracks)) return this.failAll(me, "bad_message", "queue.addMany needs tracks");
    return this.addTracks(me, msg.tracks.slice(0, MAX_ADD_MANY), msg.next === true);
  }

  /** Puts valid tracks on the queue in the given order, at the end or right after the current item. */
  private async addTracks(me: Attachment, tracks: TrackInput[], playNext: boolean): Promise<void> {
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
      items.push({ id: crypto.randomUUID(), ...cleanTrack(track), addedBy: me.clientId });
    }
    if (items.length === 0) return;

    // "Play next" only makes sense while something is playing; otherwise the new items simply go last
    const at = playNext && this.s.phase !== "idle" ? this.s.index + 1 : this.s.queue.length;
    this.s.queue.splice(at, 0, ...items);

    if (this.s.phase === "idle") {
      await this.begin(at, 0);
    } else {
      await this.save();
      this.broadcastState();
    }
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
      return this.begin(at, positionMs, me.clientId);
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
    shuffleInPlace(this.s.queue, this.s.index + 1);
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

  private async onReady(clientId: string, epoch: number): Promise<void> {
    if (this.s.phase !== "preparing" || epoch !== this.s.epoch) return;
    if (!this.s.readyIds.includes(clientId)) this.s.readyIds.push(clientId);
    await this.save();
    this.broadcastMembers();
    await this.maybeStart();
  }

  /** A device could not load the item. It counts as answered, so it never holds the others back. */
  private async onResolveFailed(clientId: string, epoch: number): Promise<void> {
    if (this.s.phase !== "preparing" || epoch !== this.s.epoch) return;
    if (!this.s.failedIds.includes(clientId)) this.s.failedIds.push(clientId);
    return this.onReady(clientId, epoch);
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
      return this.onNext();
    }
    await this.startPlayback();
  }

  private async startPlayback(by?: string): Promise<void> {
    const startAt = Date.now() + LEAD_MS;
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
    if (this.s.phase !== "playing") return;
    this.s.positionMs = this.currentPositionMs();
    this.s.phase = "paused";
    this.s.epoch++;
    await this.clearAlarm("end");
    this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs, by });
  }

  private async onSeek(positionMs: number, by: string): Promise<void> {
    if (this.s.phase !== "playing" && this.s.phase !== "paused") return;
    if (typeof positionMs !== "number" || !Number.isFinite(positionMs)) return;
    const item = this.s.queue[this.s.index];
    this.s.positionMs = clamp(positionMs, 0, item?.durMs || Number.MAX_SAFE_INTEGER);
    this.s.epoch++;
    if (this.s.phase === "playing") return this.startPlayback(by);
    await this.save();
    this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs, by });
  }

  /** [by] is set when a person asked for it; when the queue simply reaches the next item it is left out. */
  private async onNext(by?: string): Promise<void> {
    if (this.s.phase === "idle") return;
    if (this.s.index + 1 < this.s.queue.length) return this.begin(this.s.index + 1, 0, by);
    if (this.s.repeat === "all") return this.begin(0, 0, by);
    return this.goIdle();
  }

  /** The current item played to its end: repeat it, or move on like the next button does. */
  private async onFinished(): Promise<void> {
    if (this.s.repeat === "one" && this.s.queue[this.s.index]) return this.begin(this.s.index, 0);
    return this.onNext();
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
      this.s = defaultState();
      this.created = false;
      await this.ctx.storage.deleteAll();
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
        id: att.clientId,
        name: att.name,
        ready: this.s.readyIds.includes(att.clientId),
        solo: att.solo === true,
        away: now - att.lastSeen > limit,
        owner: att.clientId === this.s.ownerId,
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
    const { readyIds: _r, failedIds: _f, alarms: _a, ...rest } = this.s;
    return rest;
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
      if (att) this.send(ws, this.stateMessage(att.clientId));
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

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/** Fisher-Yates over the items from [from] to the end, with an unbiased random source. */
function shuffleInPlace<T>(items: T[], from: number): void {
  for (let i = items.length - 1; i > from; i--) {
    const range = i - from + 1;
    const j = from + Math.floor((crypto.getRandomValues(new Uint32Array(1))[0] / 2 ** 32) * range);
    [items[i], items[j]] = [items[j], items[i]];
  }
}
