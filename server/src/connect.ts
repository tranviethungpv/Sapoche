/**
 * Connect: the devices of one person, playing one queue (docs/PROTOCOL.md "Connect"). Apart from the rooms: it shares nothing
 * with room.ts, not a message, a limit or a stored byte.
 *
 * One Durable Object per cluster. The cluster is named by the app from the sync key (`clusterId`, 64 hex digits) and entered
 * with a token that comes from the same key; the first device to come fixes the hash of the token, as `/sync` does. Every
 * word of content (the name of a device, the song, the queue, a command) is sealed by the apps with a key the server never
 * has: here it is a string to carry. What this object knows is who is connected, under a public id (a hash, as rooms do), which
 * of them plays, and the last state it was told, so that a device that finds nobody playing can go on from it.
 *
 * Exactly one device plays at a time (`active`). It is the one who is told where the others ask for something (`cmd`), and the
 * only one who may say what is playing (`state`, `queue`). A change of device goes through `transfer`: the playing device is
 * asked to let go and hands its queue over; if it does not answer in time (or is gone) the last queue kept is given instead.
 */
import { DurableObject } from "cloudflare:workers";
import { logEvent } from "./log";

/** `/connect/<clusterId>`: the WebSocket of a cluster. */
export const CONNECT_ROUTE = /^\/connect\/([0-9a-f]{64})$/;

/** The version of this protocol; `/health` says it as `connect`. Only grows, and only by adding. */
export const CONNECT_VERSION = 1;

/** Devices at once in a cluster. */
const MAX_DEVICES = 12;
/** What a message may weigh (characters): a queue or a hand-over is the big one, a SQLite row of the storage holds 2 MB. */
const MAX_BIG_CHARS = 1_500_000;
const MAX_CMD_CHARS = 262_144;
const MAX_SMALL_CHARS = 16_384;
const MAX_MESSAGES_PER_SECOND = 20;
/** How long the playing device has to hand its queue over before the last one kept is used (the tests shorten it). */
const HANDOFF_MS = 6000;

const TOKEN_MIN = 16;
const TOKEN_MAX = 128;

interface Attachment {
  /** The public id: the start of a hash of the secret one the device sent. */
  id: string;
  /** What the device says about itself, sealed. */
  info: string;
}

interface Stored {
  /** SHA-256 of the cluster token. */
  auth?: string;
  /** The public id of the device that plays, if any. */
  active: string | null;
  /** The last state the playing device sent, sealed. */
  state: { rev: number; blob: string; at: number } | null;
  /** The last full queue the playing device sent, sealed. */
  queue: string | null;
  /** A change of device under way. */
  pending: { from: string; to: string } | null;
}

type ClientMessage =
  | { t: "hello"; v?: number; token: string; clientId: string; info?: string }
  | { t: "ping"; c0: number }
  | { t: "info"; info: string }
  | { t: "state"; rev: number; blob: string }
  | { t: "queue"; blob: string }
  | { t: "cmd"; to: string; blob: string }
  | { t: "transfer"; to: string }
  | { t: "claim" }
  | { t: "stop" }
  | { t: "handoff"; blob: string }
  | { t: "bye" };

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Compares two hashes (of the same length) without leaking, through timing, how much of a guess was right. */
function sameHash(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const isText = (value: unknown, max: number): value is string => typeof value === "string" && value.length <= max;

export class Connect extends DurableObject<Env> {
  private s: Stored = { active: null, state: null, queue: null, pending: null };
  private buckets = new WeakMap<WebSocket, { tokens: number; last: number }>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const saved = await ctx.storage.get<Stored>("s");
      if (saved) this.s = { ...this.s, ...saved };
    });
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected a WebSocket upgrade", { status: 426 });
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (typeof raw !== "string" || raw.length > MAX_BIG_CHARS + 1024) return this.fail(ws, "bad_message", "Text of at most 1.5 million characters is expected");
    if (!this.allow(ws)) return this.fail(ws, "rate_limited", "Too many messages");
    let msg: ClientMessage;
    try {
      msg = JSON.parse(raw) as ClientMessage;
    } catch {
      return this.fail(ws, "bad_json", "Invalid JSON");
    }
    if (typeof msg !== "object" || msg === null || typeof msg.t !== "string") return this.fail(ws, "bad_message", "Missing message type");
    const limit = msg.t === "queue" || msg.t === "handoff" ? MAX_BIG_CHARS : msg.t === "cmd" ? MAX_CMD_CHARS : MAX_SMALL_CHARS;
    if (raw.length > limit + 1024) return this.fail(ws, "bad_message", "Message too big");

    if (msg.t === "ping") {
      if (typeof msg.c0 !== "number") return this.fail(ws, "bad_message", "ping needs c0");
      return this.send(ws, { t: "pong", c0: msg.c0, s1: Date.now() });
    }
    if (msg.t === "hello") return this.onHello(ws, msg);

    const me = ws.deserializeAttachment() as Attachment | null;
    if (!me) return this.fail(ws, "not_joined", "Send hello first");

    switch (msg.t) {
      case "info":
        if (!isText(msg.info, MAX_SMALL_CHARS)) return this.fail(ws, "bad_message", "info needs text");
        this.setInfo(me.id, msg.info);
        return this.broadcastDevices();
      case "state":
        if (this.s.active !== me.id) return this.fail(ws, "not_active", "Only the device that plays says what plays");
        if (typeof msg.rev !== "number" || !isText(msg.blob, MAX_SMALL_CHARS * 8)) return this.fail(ws, "bad_message", "state needs rev and blob");
        this.s.state = { rev: msg.rev, blob: msg.blob, at: Date.now() };
        await this.save();
        return this.sendToOthers(me.id, { t: "state", from: me.id, rev: msg.rev, blob: msg.blob });
      case "queue":
        if (this.s.active !== me.id) return this.fail(ws, "not_active", "Only the device that plays says what plays");
        if (!isText(msg.blob, MAX_BIG_CHARS)) return this.fail(ws, "bad_message", "queue needs blob");
        this.s.queue = msg.blob;
        await this.save();
        // The others show the queue, and are the ones to hand over to when this device goes
        return this.sendToOthers(me.id, { t: "queue", from: me.id, blob: msg.blob });
      case "cmd": {
        if (typeof msg.to !== "string" || !isText(msg.blob, MAX_CMD_CHARS)) return this.fail(ws, "bad_message", "cmd needs to and blob");
        if (!this.sendToDevice(msg.to, { t: "cmd", from: me.id, blob: msg.blob })) return this.fail(ws, "gone", "That device is not here");
        return;
      }
      case "transfer":
        return this.onTransfer(ws, me, msg.to);
      case "claim":
        return this.onClaim(me);
      case "stop":
        // The playing device stops being it (it went into a room): the last state stays, as when it goes away
        if (this.s.active !== me.id) return;
        this.s.pending = null;
        await this.ctx.storage.deleteAlarm();
        return this.setActive(null);
      case "handoff":
        return this.onHandoff(ws, me, msg.blob);
      case "bye":
        ws.close(1000, "bye");
        return this.afterClose(ws);
      default:
        return this.fail(ws, "bad_message", "Unknown message type");
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    ws.close(1000, "closed");
    await this.afterClose(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    ws.close(1011, "error");
    await this.afterClose(ws);
  }

  async alarm(): Promise<void> {
    const pending = this.s.pending;
    if (pending) await this.finishTransfer(pending.to, this.s.queue);
  }

  // ------------------------------------------------------------------ messages

  private async onHello(ws: WebSocket, msg: Extract<ClientMessage, { t: "hello" }>): Promise<void> {
    const token = msg.token;
    if (typeof token !== "string" || token.length < TOKEN_MIN || token.length > TOKEN_MAX) {
      return this.refuse(ws, "bad_token", "A token of 16 to 128 characters is needed");
    }
    if (typeof msg.clientId !== "string" || !msg.clientId || msg.clientId.length > 64) return this.refuse(ws, "bad_message", "hello needs clientId");
    const info = msg.info === undefined ? "" : msg.info;
    if (!isText(info, MAX_SMALL_CHARS)) return this.refuse(ws, "bad_message", "info is too big");

    const hash = await sha256Hex(token);
    if (this.s.auth === undefined) {
      this.s.auth = hash;
    } else if (!sameHash(this.s.auth, hash)) {
      return this.refuse(ws, "bad_token", "Wrong token");
    }
    const id = (await sha256Hex(`sapoche-device:${msg.clientId}`)).slice(0, 16);

    // The same device again: its older connection is dropped. A twelfth device is the one that does not fit
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      if ((other.deserializeAttachment() as Attachment | null)?.id === id) {
        other.serializeAttachment(null);
        other.close(4000, "replaced");
      }
    }
    const here = new Set(this.devices().map((d) => d.id));
    here.delete(id);
    if (here.size >= MAX_DEVICES) return this.refuse(ws, "full", `At most ${MAX_DEVICES} devices`);

    ws.serializeAttachment({ id, info } satisfies Attachment);
    await this.save();
    logEvent("connect.hello", { devices: here.size + 1 });
    this.send(ws, {
      t: "welcome",
      v: CONNECT_VERSION,
      you: id,
      devices: this.devices(),
      active: this.s.active,
      state: this.s.state,
      queue: this.s.queue,
      now: Date.now(),
    });
    this.broadcastDevices(ws);
  }

  private async onTransfer(ws: WebSocket, me: Attachment, to: unknown): Promise<void> {
    if (typeof to !== "string" || !this.isHere(to)) return this.fail(ws, "gone", "That device is not here");
    const from = this.s.active;
    if (from === to) return this.setActive(to);
    if (from === null || !this.isHere(from)) return this.finishTransfer(to, this.s.queue);
    // The playing device lets go and hands over what it has; if it never does, the alarm hands over what was kept
    this.s.pending = { from, to };
    await this.save();
    await this.ctx.storage.setAlarm(Date.now() + this.handoffMs());
    this.sendToDevice(from, { t: "release", to, by: me.id });
  }

  private async onHandoff(ws: WebSocket, me: Attachment, blob: unknown): Promise<void> {
    const pending = this.s.pending;
    if (!pending || pending.from !== me.id) return this.fail(ws, "bad_message", "Nothing was asked of you");
    if (!isText(blob, MAX_BIG_CHARS)) return this.fail(ws, "bad_message", "handoff needs blob");
    // What the old device hands over is also what is kept now
    this.s.queue = blob;
    await this.finishTransfer(pending.to, blob, pending.from);
  }

  /** A device starts playing by itself (nothing to hand over): the one that played is told to stop. */
  private async onClaim(me: Attachment): Promise<void> {
    const from = this.s.active;
    this.s.pending = null;
    await this.ctx.storage.deleteAlarm();
    if (from !== null && from !== me.id) this.sendToDevice(from, { t: "deposed", by: me.id });
    this.s.queue = null;
    this.s.state = null;
    await this.setActive(me.id);
  }

  /** Makes [to] the playing device and gives it [blob]: the queue the last one handed over, or the last one kept. */
  private async finishTransfer(to: string, blob: string | null, from: string | null = this.s.pending?.from ?? null): Promise<void> {
    this.s.pending = null;
    await this.ctx.storage.deleteAlarm();
    // The state of the old device says nothing about the new one until it speaks
    this.s.state = null;
    await this.setActive(to);
    this.sendToDevice(to, { t: "handoff", from, blob });
  }

  private async setActive(id: string | null): Promise<void> {
    this.s.active = id;
    await this.save();
    this.broadcast({ t: "active", device: id });
  }

  private async afterClose(ws: WebSocket): Promise<void> {
    const me = ws.deserializeAttachment() as Attachment | null;
    if (!me) return;
    // Another connection of the same device (it came back before this one was seen to close) keeps it here
    if (this.isHere(me.id, ws)) return;
    const pending = this.s.pending;
    if (pending && pending.from === me.id) {
      await this.finishTransfer(pending.to, this.s.queue);
    } else if (pending && pending.to === me.id) {
      this.s.pending = null;
      await this.ctx.storage.deleteAlarm();
      await this.save();
    }
    // Nobody plays when the one that did is gone; the last state stays for whoever comes to go on from it
    if (this.s.active === me.id) await this.setActive(null);
    this.broadcastDevices(undefined, ws);
  }

  // ------------------------------------------------------------------ helpers

  private handoffMs(): number {
    return Number(this.env.CONNECT_HANDOFF_MS) > 0 ? Number(this.env.CONNECT_HANDOFF_MS) : HANDOFF_MS;
  }

  private live(except?: WebSocket): { ws: WebSocket; att: Attachment }[] {
    const found: { ws: WebSocket; att: Attachment }[] = [];
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except) continue;
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att) found.push({ ws, att });
    }
    return found;
  }

  private isHere(id: string, except?: WebSocket): boolean {
    return this.live(except).some((d) => d.att.id === id);
  }

  private devices(except?: WebSocket): { id: string; info: string }[] {
    const byId = new Map<string, string>();
    for (const { att } of this.live(except)) byId.set(att.id, att.info);
    return Array.from(byId, ([id, info]) => ({ id, info }));
  }

  private setInfo(id: string, info: string): void {
    for (const { ws, att } of this.live()) if (att.id === id) ws.serializeAttachment({ ...att, info } satisfies Attachment);
  }

  /** The list of devices to everyone but [skip]; [gone] is a connection that is closing and is not in it. */
  private broadcastDevices(skip?: WebSocket, gone?: WebSocket): void {
    this.broadcast({ t: "devices", devices: this.devices(gone), active: this.s.active }, skip ?? gone);
  }

  private broadcast(msg: object, except?: WebSocket): void {
    for (const { ws } of this.live(except)) this.send(ws, msg);
  }

  private sendToOthers(id: string, msg: object): void {
    for (const { ws, att } of this.live()) if (att.id !== id) this.send(ws, msg);
  }

  private sendToDevice(id: string, msg: object): boolean {
    let sent = false;
    for (const { ws, att } of this.live()) {
      if (att.id !== id) continue;
      this.send(ws, msg);
      sent = true;
    }
    return sent;
  }

  private send(ws: WebSocket, msg: object): void {
    try {
      ws.send(JSON.stringify(msg));
    } catch {
      // The socket is closing; the close handler will clean up
    }
  }

  private fail(ws: WebSocket, code: string, message: string): void {
    logEvent("connect.fail", { code });
    this.send(ws, { t: "error", code, message });
  }

  /** An error that ends the connection: a device that is not let in has nothing more to say. */
  private refuse(ws: WebSocket, code: string, message: string): void {
    this.fail(ws, code, message);
    ws.close(4001, code);
  }

  private async save(): Promise<void> {
    await this.ctx.storage.put("s", this.s);
  }

  private allow(ws: WebSocket): boolean {
    const now = Date.now();
    const bucket = this.buckets.get(ws) ?? { tokens: MAX_MESSAGES_PER_SECOND, last: now };
    bucket.tokens = Math.min(MAX_MESSAGES_PER_SECOND, bucket.tokens + ((now - bucket.last) / 1000) * MAX_MESSAGES_PER_SECOND);
    bucket.last = now;
    this.buckets.set(ws, bucket);
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }
}
