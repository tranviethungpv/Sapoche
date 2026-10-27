// Wire protocol between clients and the room Durable Object. See docs/PROTOCOL.md.

/** Bumped when the set of messages grows or changes. Reported by /health and in every state message. */
export const PROTOCOL_VERSION = 16;

export interface QueueItem {
  id: string;
  videoId: string;
  title: string;
  artist: string;
  thumb?: string;
  durMs: number;
  addedBy: string;
  /** Put on the queue by autoplay, not by a member: it stays after the songs members chose and is dropped once played. Protocol 12. */
  auto?: true;
}

export type Phase = "idle" | "preparing" | "playing" | "paused";

/** What happens when an item ends: stop after the queue, start it over, or repeat the same item. */
export type Repeat = "off" | "all" | "one";

/** What guests may do while the owner is in the room: everything, or only add songs. */
export type GuestControl = "all" | "add";

/** The jobs a room can have pending. The Durable Object has one alarm, always set to the earliest of them. */
export type AlarmKind = "barrier" | "end" | "gc" | "sweep";

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
  /** Room name, shown to members and in the recent rooms list. */
  name?: string;
  /** The look of the room's chat, one of the names the apps know; absent for the default (the state sent says `default`). Protocol 16. */
  theme?: string;
  /** Fingerprint (8 hexadecimal digits) of the picture behind the chat, which is fetched with `avatar.get` for `room:bg`. Protocol 16. */
  bg?: string;
  /** Client id of the owner; absent while nobody owns the room (it is empty, or predates owners). */
  ownerId?: string;
  guestControl: GuestControl;
  /** Whether the room carries on with songs like the last one when its queue runs out. */
  autoplay: boolean;
  /** Whether the songs still to come are mixed up and stay mixed as songs are added. Protocol 11. */
  shuffle: boolean;
  /** The ids of the queue in the order it had when shuffle was turned on; turning it off puts the songs back in it. */
  shuffleOrder?: string[];
  /** The chat is end-to-end encrypted: the room keeps and passes on sealed messages only. Never goes back. Protocol 15. */
  enc?: true;
  /** When each pending job is due, in server time. */
  alarms: Partial<Record<AlarmKind, number>>;
}

/** A chat message as the room keeps it and sends it. [name] is the sender's name when it was sent, so it outlives them. */
export interface ChatMessage {
  /** Increases by one with every message of the room. */
  id: number;
  by: string;
  name: string;
  text: string;
  /** Server time it was sent at. */
  at: number;
  /** The id the sending device gave it, so that device knows the message arrived; absent when it gave none. */
  cid?: string;
  /**
   * In a room with end-to-end encryption [text] is empty and the words are here, sealed with the room's key, with the
   * answered message's quote inside; the server cannot read them. Protocol 15.
   */
  ct?: string;
  /** The start of the words, sealed apart, so that a notice can show them without the whole message. Protocol 15. */
  pv?: string;
  /** The message this one answers, as it was when the answer was written. Protocol 12. */
  re?: ChatQuote;
  /** Reactions to this message, by the public id of each member who gave one; the value is a name of [REACTIONS] or an emoji. Protocol 12. */
  rx?: Record<string, string>;
}

/** What a reply shows of the message it answers, kept with it so it outlives that message in the room's last 100. */
export interface ChatQuote {
  id: number;
  by: string;
  name: string;
  /** The start of the text, at most [QUOTE_CHARS] characters. */
  text: string;
}

/** What a member has got of the chat: [d] the last message that reached their device, [r] the last one they looked at. Protocol 12. */
export interface ChatReceipt {
  d: number;
  r: number;
}

/** The reactions that go by name, as they did before any emoji could be sent. Apps of that time know only these. */
export const REACTIONS = [
  "heart", "love", "kiss", "hug", "blush", "cool", "wink", "pleading",
  "laugh", "rofl", "grin", "wow", "mindblown", "think", "eyes", "sad",
  "cry", "skull", "sleepy", "fire", "clap", "raise", "party", "hundred",
  "sparkles", "rocket", "muscle", "thumbsup", "thumbsdown", "ok", "pray", "music",
  "dance", "headphones", "mic", "guitar", "drum", "speaker", "replay",
] as const;

export type Reaction = (typeof REACTIONS)[number];

/** Most UTF-16 units one emoji takes: a family or a flag of a region joins up to a dozen. */
const MAX_EMOJI_UNITS = 32;

/**
 * Whether [e] is one emoji as a keyboard offers it: pictographs, flags, skin tones, joined and keycap forms. Written
 * as what an emoji is made of and not as a list, so emoji newer than this server still pass.
 */
export function isEmoji(e: string): boolean {
  return e.length <= MAX_EMOJI_UNITS && EMOJI.test(e);
}

const EMOJI =
  /^(?=.*[\p{Extended_Pictographic}\p{Regional_Indicator}\u20E3])(?:\p{Extended_Pictographic}|\p{Regional_Indicator}|\p{Emoji_Modifier}|[\uFE0F\u200D\u20E3#*0-9]|[\u{E0020}-\u{E007F}])+$/u;

export interface Member {
  id: string;
  name: string;
  ready: boolean;
  /** Listening on their own: the room's play, pause and skip do not move this device. */
  solo: boolean;
  /** Not heard from for a while: probably a dead connection, not counted as listening. */
  away: boolean;
  /** Can change the room's settings and remove people. */
  owner: boolean;
  /** Short fingerprint of the member's picture; absent when they have none. The picture itself comes with avatar.get. */
  av?: string;
}

// ---- client -> server ----

export type ClientMessage =
  /**
   * [create] says what the device expects: true when it just made the code up, false when it was
   * given one (a typo must not open an empty room). Absent means an older app, which gets the old behavior.
   */
  | { t: "join"; clientId: string; name: string; create?: boolean; caps?: string[] }
  /** Owner only: turns on end-to-end encryption of the chat, for good. The chat so far is deleted. Protocol 15. */
  | { t: "room.encrypt" }
  /** Leaving on purpose, as opposed to a connection that dropped. An owner who says this hands the room over. */
  | { t: "bye" }
  /** Owner only: remove a member. The device is disconnected and may join again. */
  | { t: "kick"; id: string }
  | { t: "room.name"; name: string }
  /** The look of the chat for the whole room; restricted like the name. Protocol 16. */
  | { t: "room.theme"; theme: string; bg?: string | null }
  /** Owner only. */
  | { t: "room.settings"; guestControl: GuestControl }
  /** [rtt] is the best round trip the device measured; the room schedules starts from the slowest. Absent from older apps. */
  | { t: "ping"; c0: number; rtt?: number }
  /** The member's own picture, as base64 of a small JPEG or PNG; null takes it away. Pictures are not part of the member list. */
  | { t: "avatar.set"; data: string | null }
  /** Asks for the picture of the member [id]; answered with an avatar message to this socket only. */
  | { t: "avatar.get"; id: string }
  /** With [next] the item goes right after the current one instead of at the end of the queue. */
  | { t: "queue.add"; videoId: string; title: string; artist: string; thumb?: string; durMs: number; next?: boolean }
  /**
   * Adds several songs in one go (a playlist). With [next] they go right after the current item. With [auto] they are
   * what autoplay found for a room that ran out: the room takes them only while it is idle, and keeps them apart from
   * the songs members chose. Protocol 12.
   */
  | { t: "queue.addMany"; tracks: TrackInput[]; next?: boolean; auto?: boolean }
  | { t: "queue.remove"; id: string }
  /**
   * Replaces the queue item [id] by another release of the same song (its video for its audio, or back),
   * keeping its place. If it is the current item, everyone loads the new one and carries on from the same position.
   */
  | { t: "queue.swap"; id: string; track: TrackInput }
  | { t: "queue.clear" }
  /** Mixes up the songs still to come; with nothing playing (the queue has finished) it mixes them all and plays from the first. */
  | { t: "queue.shuffle" }
  /** Start playing the queue item [id] from the beginning. */
  | { t: "jump"; id: string }
  | { t: "queue.move"; id: string; toIndex: number }
  | { t: "play" }
  | { t: "pause" }
  | { t: "seek"; positionMs: number }
  /**
   * [from] is the id of the item the button was pressed on: when the room has already left it (somebody else skipped
   * first) the press is ignored, so two people skipping at once move the room one item, not two. Absent from older apps.
   */
  | { t: "next"; from?: string }
  | { t: "prev"; from?: string }
  | { t: "repeat"; mode: Repeat }
  /** Turns the room's autoplay on or off, restricted like [repeat]. Protocol 9. */
  | { t: "autoplay"; on: boolean }
  /** Turns the room's shuffle on or off, restricted like [repeat]. Protocol 11. */
  | { t: "shuffle"; on: boolean }
  /**
   * Asks to be told of chat while away: the browser's push [sub]scription, the [room] to open when the notice is
   * touched, and until when to keep quiet ([until], server time in ms; absent for not at all). [preview] false keeps
   * the text of the messages out of the notices; [lang] is the language the notice is written in. Sent again at every
   * join. Protocol 13.
   */
  | { t: "push.set"; sub: { endpoint: string; keys: { p256dh: string; auth: string } }; room: string; until?: number; preview?: boolean; lang?: string }
  /** Stops being told of chat. Leaving the room does this too. Protocol 13. */
  | { t: "push.clear" }
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
  | { t: "report"; epoch: number; posMs: number; bufferMs: number }
  /** A chat message to everybody; [cid] is the device's own id for it, sent back with it; [reply] the number of the message it answers (protocol 12). Protocol 10. */
  | { t: "chat"; text?: string; cid?: string; reply?: number; ct?: string; pv?: string }
  /** A reaction, [n] times in a row (1 when absent): one of the names in [REACTIONS], or an emoji. Not kept. Protocol 10. */
  | { t: "react"; e: string; n?: number }
  /** This member's reaction to the chat message [id]: a name of [REACTIONS] or an emoji, null takes it away. Protocol 12. */
  | { t: "chat.react"; id: number; e: string | null }
  /** What the device has got of the chat: [delivered] the last message that reached it, [read] the last one it showed. Protocol 12. */
  | { t: "chat.receipt"; delivered?: number; read?: number }
  /** Asks for up to [n] (50 when absent, at most 100) of the chat messages older than number [id]; answered with `chat.page` to this socket only. Protocol 14. */
  | { t: "chat.before"; id: number; n?: number };

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
  /**
   * The queue ran out and autoplay is on: sent to one device that is here, which answers with `queue.addMany` of songs
   * like [videoId]. Protocol 9.
   */
  | { t: "autoplay.fill"; epoch: number; videoId: string; title: string }
  /** The picture of [id] ([av] is its fingerprint); both are absent when that member has none. */
  | { t: "avatar"; id: string; av?: string; data?: string }
  /** A new chat message, sent to everybody including its sender. Protocol 10. */
  | { t: "chat"; msg: ChatMessage }
  /** The room's last chat messages, oldest first, sent to a device right after the state it gets on joining. Protocol 10. [receipts] since 12. */
  | { t: "chat.history"; msgs: ChatMessage[]; receipts?: Record<string, ChatReceipt>; more?: boolean }
  /** Older chat messages the device asked for with `chat.before`, oldest first; [more] says whether the room keeps messages from before them. Protocol 14. */
  | { t: "chat.page"; before: number; msgs: ChatMessage[]; more: boolean }
  /** A message changed (somebody reacted to it): the new version of it, to everybody. Protocol 12. */
  | { t: "chat.update"; msg: ChatMessage }
  /** What each member has got of the chat, by public id; sent to everybody when it changes. Protocol 12. */
  | { t: "chat.receipts"; receipts: Record<string, ChatReceipt> }
  /** Somebody else reacted, [n] times in a row. Protocol 10. */
  | { t: "react"; by: string; e: string; n: number }
  | { t: "error"; code: string; message: string };

/** State as sent to clients; internal bookkeeping is left out. */
export type PublicState = Omit<RoomState, "readyIds" | "failedIds" | "alarms" | "shuffleOrder" | "theme"> & { theme: string };
