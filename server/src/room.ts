import { DurableObject } from "cloudflare:workers";
import type {
  ClientMessage,
  Member,
  PublicState,
  QueueItem,
  RoomState,
  ServerMessage,
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
/** How long an empty room keeps its state before it is deleted. */
const EMPTY_ROOM_TTL_MS = 24 * 60 * 60 * 1000;

const MAX_MEMBERS = 12;
const MAX_QUEUE = 200;
const MAX_MESSAGE_CHARS = 4096;
const MAX_MESSAGES_PER_SECOND = 20;
const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;

interface Attachment {
  clientId: string;
  name: string;
}

function defaultState(): RoomState {
  return {
    queue: [],
    index: 0,
    phase: "idle",
    startedAt: 0,
    positionMs: 0,
    epoch: 0,
    readyIds: [],
    alarm: "none",
  };
}

export class Room extends DurableObject<Env> {
  private s: RoomState = defaultState();
  /** Per-socket rate limiting. Lives in memory only; losing it on hibernation is harmless. */
  private buckets = new WeakMap<WebSocket, { tokens: number; last: number }>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const saved = await ctx.storage.get<RoomState>("state");
      if (saved) this.s = saved;
    });
  }

  // ------------------------------------------------------------------ connections

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (typeof raw !== "string" || raw.length > MAX_MESSAGE_CHARS) {
      return this.fail(ws, "bad_message", "Message must be text of at most 4096 characters");
    }
    if (!this.allow(ws)) return this.fail(ws, "rate_limited", "Too many messages");

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

    switch (msg.t) {
      case "queue.add": return this.onQueueAdd(me, msg);
      case "queue.remove": return this.onQueueRemove(msg.id);
      case "queue.move": return this.onQueueMove(msg.id, msg.toIndex);
      case "play": return this.onPlay();
      case "pause": return this.onPause();
      case "seek": return this.onSeek(msg.positionMs);
      case "next": return this.onNext();
      case "prev": return this.onPrev();
      case "ready": return this.onReady(me.clientId, msg.epoch);
      case "resolveFailed": return this.onReady(me.clientId, msg.epoch); // do not hold the room hostage
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

    // The same device reconnecting: drop its stale socket
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      const att = other.deserializeAttachment() as Attachment | null;
      if (att?.clientId === clientId) other.close(1000, "replaced by a newer connection");
    }
    if (this.members().length >= MAX_MEMBERS && !this.members().some((m) => m.id === clientId)) {
      ws.close(1008, "room is full");
      return;
    }

    ws.serializeAttachment({ clientId, name } satisfies Attachment);

    // A member is back, so the empty-room cleanup no longer applies
    if (this.s.alarm === "gc") await this.setAlarm("none");

    this.send(ws, this.stateMessage(clientId));
    // A device joining mid-preparation must take part in the barrier
    if (this.s.phase === "preparing") this.send(ws, this.prepareMessage());
    this.broadcast({ t: "members", members: this.members() });
  }

  private async onMembersChanged(): Promise<void> {
    const members = this.members();
    if (members.length === 0) {
      // Nobody is listening: freeze the position and schedule cleanup
      if (this.s.phase === "playing") {
        this.s.positionMs = this.currentPositionMs();
        this.s.phase = "paused";
        this.s.epoch++;
      }
      this.s.readyIds = [];
      await this.setAlarm("gc", Date.now() + EMPTY_ROOM_TTL_MS);
      return;
    }
    this.broadcast({ t: "members", members });
    await this.maybeStart(); // the device we were waiting for may be the one that left
  }

  // ------------------------------------------------------------------ queue

  private async onQueueAdd(me: Attachment, msg: Extract<ClientMessage, { t: "queue.add" }>): Promise<void> {
    if (!VIDEO_ID.test(msg.videoId ?? "")) return this.failAll(me, "bad_video", "Invalid videoId");
    if (this.s.queue.length >= MAX_QUEUE) return this.failAll(me, "queue_full", "Queue is full");

    const item: QueueItem = {
      id: crypto.randomUUID(),
      videoId: msg.videoId,
      title: String(msg.title ?? "").slice(0, 200),
      artist: String(msg.artist ?? "").slice(0, 100),
      thumb: typeof msg.thumb === "string" ? msg.thumb.slice(0, 300) : undefined,
      durMs: clamp(Number(msg.durMs) || 0, 0, 12 * 3600 * 1000),
      addedBy: me.clientId,
    };
    this.s.queue.push(item);

    if (this.s.phase === "idle") {
      await this.begin(this.s.queue.length - 1, 0);
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
  private async begin(index: number, seekToMs: number): Promise<void> {
    this.s.index = index;
    this.s.epoch++;
    this.s.phase = "preparing";
    this.s.positionMs = seekToMs;
    this.s.startedAt = 0;
    this.s.readyIds = [];
    await this.setAlarm("barrier", Date.now() + BARRIER_TIMEOUT_MS);
    this.broadcastState();
    this.broadcast(this.prepareMessage());
    await this.maybeStart();
  }

  private async onReady(clientId: string, epoch: number): Promise<void> {
    if (this.s.phase !== "preparing" || epoch !== this.s.epoch) return;
    if (!this.s.readyIds.includes(clientId)) this.s.readyIds.push(clientId);
    await this.save();
    this.broadcast({ t: "members", members: this.members() });
    await this.maybeStart();
  }

  /** Releases the barrier once every connected device is ready. */
  private async maybeStart(): Promise<void> {
    if (this.s.phase !== "preparing") return;
    const members = this.members();
    if (members.length > 0 && members.every((m) => m.ready)) await this.startPlayback();
  }

  private async startPlayback(): Promise<void> {
    const startAt = Date.now() + LEAD_MS;
    this.s.phase = "playing";
    this.s.startedAt = startAt - this.s.positionMs;
    this.s.readyIds = [];
    await this.scheduleEnd();
    this.broadcast({ t: "start", epoch: this.s.epoch, startAt, positionMs: this.s.positionMs });
  }

  private async onPlay(): Promise<void> {
    if (this.s.phase === "paused") {
      this.s.epoch++;
      return this.startPlayback();
    }
    if (this.s.phase === "idle" && this.s.queue[this.s.index]) return this.begin(this.s.index, 0);
  }

  private async onPause(): Promise<void> {
    if (this.s.phase !== "playing") return;
    this.s.positionMs = this.currentPositionMs();
    this.s.phase = "paused";
    this.s.epoch++;
    await this.setAlarm("none");
    this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs });
  }

  private async onSeek(positionMs: number): Promise<void> {
    if (this.s.phase !== "playing" && this.s.phase !== "paused") return;
    if (typeof positionMs !== "number" || !Number.isFinite(positionMs)) return;
    const item = this.s.queue[this.s.index];
    this.s.positionMs = clamp(positionMs, 0, item?.durMs || Number.MAX_SAFE_INTEGER);
    this.s.epoch++;
    if (this.s.phase === "playing") return this.startPlayback();
    await this.save();
    this.broadcast({ t: "pause", epoch: this.s.epoch, positionMs: this.s.positionMs });
  }

  private async onNext(): Promise<void> {
    if (this.s.phase === "idle") return;
    if (this.s.index + 1 < this.s.queue.length) return this.begin(this.s.index + 1, 0);
    return this.goIdle();
  }

  private async onPrev(): Promise<void> {
    if (this.s.phase === "idle") return;
    // Like most players: restart the current item unless we are right at its start
    if (this.currentPositionMs() > 3000) return this.begin(this.s.index, 0);
    return this.begin(Math.max(0, this.s.index - 1), 0);
  }

  /** A device reports the item finished. The first report for the current epoch advances the queue. */
  private async onEnded(epoch: number): Promise<void> {
    if (epoch !== this.s.epoch || this.s.phase !== "playing") return;
    const item = this.s.queue[this.s.index];
    // Ignore reports that arrive implausibly early
    if (item && item.durMs > 0 && this.currentPositionMs() < item.durMs - 5000) return;
    return this.onNext();
  }

  /**
   * A device already moved on to the next item on its own, so devices that preloaded it need no
   * barrier and no gap. The first plausible report fixes the new start time for everyone.
   */
  private async onAdvanced(epoch: number, itemId: string, startedAt: number): Promise<void> {
    if (this.s.phase !== "playing" || epoch !== this.s.epoch) return;
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
    this.s.index = Math.min(this.s.index, Math.max(0, this.s.queue.length - 1));
    await this.setAlarm("none");
    this.broadcastState();
  }

  // ------------------------------------------------------------------ alarm

  async alarm(): Promise<void> {
    const kind = this.s.alarm;
    this.s.alarm = "none";
    if (kind === "barrier") {
      // Start without the devices that did not answer in time; they catch up when they finish loading
      if (this.s.phase === "preparing" && this.members().length > 0) await this.startPlayback();
    } else if (kind === "end") {
      if (this.s.phase === "playing") await this.onNext();
    } else if (kind === "gc") {
      if (this.members().length === 0) {
        this.s = defaultState();
        await this.ctx.storage.deleteAll();
        return;
      }
    }
    await this.save();
  }

  private async scheduleEnd(): Promise<void> {
    const item = this.s.queue[this.s.index];
    if (!item || item.durMs <= 0) return this.setAlarm("none");
    await this.setAlarm("end", this.s.startedAt + item.durMs + END_GRACE_MS);
  }

  private async setAlarm(kind: RoomState["alarm"], at?: number): Promise<void> {
    this.s.alarm = kind;
    if (kind === "none" || at === undefined) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(at);
    await this.save();
  }

  // ------------------------------------------------------------------ helpers

  private currentPositionMs(): number {
    if (this.s.phase === "playing") return Math.max(0, Date.now() - this.s.startedAt);
    return this.s.positionMs;
  }

  private members(): Member[] {
    const out: Member[] = [];
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att) out.push({ id: att.clientId, name: att.name, ready: this.s.readyIds.includes(att.clientId) });
    }
    return out;
  }

  private publicState(): PublicState {
    const { readyIds: _r, alarm: _a, ...rest } = this.s;
    return rest;
  }

  private stateMessage(you: string): ServerMessage {
    return { t: "state", serverNow: Date.now(), you, state: this.publicState(), members: this.members() };
  }

  private prepareMessage(): ServerMessage {
    return {
      t: "prepare",
      epoch: this.s.epoch,
      index: this.s.index,
      item: this.s.queue[this.s.index],
      seekToMs: this.s.positionMs,
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
