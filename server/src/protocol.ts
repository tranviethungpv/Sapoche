// Wire protocol between clients and the room Durable Object. See docs/PROTOCOL.md.

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
  /** Bumped on every change that invalidates what clients were doing (track change, seek, play, pause). */
  epoch: number;
  /** Client ids that reported ready for the current epoch. Only meaningful while preparing. */
  readyIds: string[];
  /** What the single Durable Object alarm is currently for. */
  alarm: "none" | "barrier" | "end" | "gc";
}

export interface Member {
  id: string;
  name: string;
  ready: boolean;
}

// ---- client -> server ----

export type ClientMessage =
  | { t: "join"; clientId: string; name: string }
  | { t: "ping"; c0: number }
  | { t: "queue.add"; videoId: string; title: string; artist: string; thumb?: string; durMs: number }
  | { t: "queue.remove"; id: string }
  | { t: "queue.move"; id: string; toIndex: number }
  | { t: "play" }
  | { t: "pause" }
  | { t: "seek"; positionMs: number }
  | { t: "next" }
  | { t: "prev" }
  | { t: "ready"; epoch: number }
  | { t: "resolveFailed"; epoch: number; reason?: string }
  | { t: "ended"; epoch: number }
  | { t: "report"; epoch: number; posMs: number; bufferMs: number };

// ---- server -> client ----

export type ServerMessage =
  | { t: "state"; serverNow: number; you: string; state: PublicState; members: Member[] }
  | { t: "members"; members: Member[] }
  | { t: "prepare"; epoch: number; index: number; item: QueueItem; seekToMs: number }
  /** Play the current item so that its position [positionMs] is heard at server time [startAt]. */
  | { t: "start"; epoch: number; startAt: number; positionMs: number }
  | { t: "pause"; epoch: number; positionMs: number }
  | { t: "pong"; c0: number; s1: number }
  | { t: "error"; code: string; message: string };

/** State as sent to clients; internal bookkeeping is left out. */
export type PublicState = Omit<RoomState, "readyIds" | "alarm">;
