// Wire protocol between clients and the room Durable Object. See docs/PROTOCOL.md.

/** Bumped when a change is not backward compatible. Reported by /health and in every state message. */
export const PROTOCOL_VERSION = 4;

export interface QueueItem {
  id: string;
  videoId: string;
  title: string;
  artist: string;
  thumb?: string;
  durMs: number;
  addedBy: string;
}

export type Phase = "idle" | "preparing" | "playing" | "paused";

/** What happens when an item ends: stop after the queue, start it over, or repeat the same item. */
export type Repeat = "off" | "all" | "one";

/** A song as clients send it; the server adds the id and who added it. */
export interface TrackInput {
  videoId: string;
  title: string;
  artist: string;
  thumb?: string;
  durMs: number;
}

/** Authoritative room state, persisted in Durable Object storage. */
export interface RoomState {
  queue: QueueItem[];
  /** Index of the current item in the queue. */
  index: number;
  phase: Phase;
  /** Server time at which the current item's position 0 is (or would be) played. Valid while playing. */
  startedAt: number;
  /** Position in the current item. Authoritative while paused or preparing. */
  positionMs: number;
  repeat: Repeat;
  /** Bumped on every change that invalidates what clients were doing (track change, seek, play, pause). */
  epoch: number;
  /** Client ids that reported ready for the current epoch. Only meaningful while preparing. */
  readyIds: string[];
  /** Client ids that could not load the current item. Only meaningful while preparing. */
  failedIds: string[];
  /** What the single Durable Object alarm is currently for. */
  alarm: "none" | "barrier" | "end" | "gc";
}

export interface Member {
  id: string;
  name: string;
  ready: boolean;
  /** Listening on their own: the room's play, pause and skip do not move this device. */
  solo: boolean;
  /** Not heard from for a while: probably a dead connection, not counted as listening. */
  away: boolean;
}

// ---- client -> server ----

export type ClientMessage =
  | { t: "join"; clientId: string; name: string }
  | { t: "ping"; c0: number }
  /** With [next] the item goes right after the current one instead of at the end of the queue. */
  | { t: "queue.add"; videoId: string; title: string; artist: string; thumb?: string; durMs: number; next?: boolean }
  /** Adds several songs in one go (a playlist). With [next] they go right after the current item. */
  | { t: "queue.addMany"; tracks: TrackInput[]; next?: boolean }
  | { t: "queue.remove"; id: string }
  | { t: "queue.clear" }
  /** Start playing the queue item [id] from the beginning. */
  | { t: "jump"; id: string }
  | { t: "queue.move"; id: string; toIndex: number }
  | { t: "play" }
  | { t: "pause" }
  | { t: "seek"; positionMs: number }
  | { t: "next" }
  | { t: "prev" }
  | { t: "repeat"; mode: Repeat }
  /** Start or stop listening on one's own. A solo device never holds the room back. */
  | { t: "solo"; on: boolean }
  /** Ask for the room's current state again, e.g. when rejoining after listening alone. */
  | { t: "resync" }
  | { t: "ready"; epoch: number }
  | { t: "resolveFailed"; epoch: number; reason?: string }
  | { t: "ended"; epoch: number }
  /**
   * The device moved on to the next queue item by itself (gapless), and [startedAt] is the server
   * time at which position 0 of that item was heard.
   */
  | { t: "advanced"; epoch: number; itemId: string; startedAt: number }
  | { t: "report"; epoch: number; posMs: number; bufferMs: number };

// ---- server -> client ----

export type ServerMessage =
  | { t: "state"; serverNow: number; you: string; protocol: number; state: PublicState; members: Member[] }
  | { t: "members"; members: Member[] }
  /** [by] is the client id of whoever caused it (skipped, picked a song); absent when the room moved on by itself. */
  | { t: "prepare"; epoch: number; index: number; item: QueueItem; seekToMs: number; by?: string }
  /** Play the current item so that its position [positionMs] is heard at server time [startAt]. */
  | { t: "start"; epoch: number; startAt: number; positionMs: number; by?: string }
  | { t: "pause"; epoch: number; positionMs: number; by?: string }
  /** The room moved on to the next item without a barrier; devices that already did the same keep playing. */
  | { t: "advance"; epoch: number; index: number; startedAt: number }
  | { t: "pong"; c0: number; s1: number }
  | { t: "error"; code: string; message: string };

/** State as sent to clients; internal bookkeeping is left out. */
export type PublicState = Omit<RoomState, "readyIds" | "failedIds" | "alarm">;
