/**
 * Files that go with chat messages (pictures). A device asks its room for a ticket per file (`media.put`), puts the
 * file on `PUT /media/<room>/<id>` with the ticket's token, and sends the message once every file is up. Members fetch
 * the files with `GET` on the same address.
 *
 * The files are encrypted by the sender with a key of their own that travels in the message, so the bucket and this
 * Worker only ever hold opaque bytes. The room (see room.ts) keeps the ledger of what it issued and gives it back when
 * the messages are gone; [MediaLedger] keeps the total across all rooms, so that the free plan of the bucket is not passed.
 */
import { DurableObject } from "cloudflare:workers";

/** A file of a room: the address of a file is `/media/<room>/<id>`. */
export const MEDIA_ROUTE = /^\/media\/([A-Za-z0-9]{6})\/([A-Za-z0-9_-]{22})$/;

/** Files in one album. */
export const MEDIA_ALBUM_MAX = 10;
/** A file takes this many bytes at most (3 MB of picture, plus the nonce and the tag of the encryption). */
const MEDIA_FILE_MAX = 3 * 1024 * 1024 + 64;
/** Per room, and for the whole account: the free plan of R2 is 10 GB, 3 of which are left to the releases. */
const MEDIA_ROOM_MAX = 1024 * 1024 * 1024;
const MEDIA_ACCOUNT_MAX = 7 * 1024 * 1024 * 1024;
/** Files one member may ask for in a day. */
const MEDIA_PER_DAY = 100;
/** How long a ticket can be used for. */
const TICKET_MS = 10 * 60 * 1000;

/** The limits, which the tests shorten (`MEDIA_*` in the environment). */
export function mediaLimits(env: Env) {
  const number = (value: string | undefined, fallback: number) => (Number(value) > 0 ? Number(value) : fallback);
  return {
    file: number(env.MEDIA_FILE_MAX, MEDIA_FILE_MAX),
    room: number(env.MEDIA_ROOM_MAX, MEDIA_ROOM_MAX),
    account: number(env.MEDIA_ACCOUNT_MAX, MEDIA_ACCOUNT_MAX),
    perDay: number(env.MEDIA_PER_DAY, MEDIA_PER_DAY),
    ticketMs: number(env.MEDIA_TICKET_MS, TICKET_MS),
  };
}

export function mediaKey(room: string, id: string): string {
  return `chat/${room}/${id}`;
}

export function newMediaId(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(16)));
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

async function signingKey(env: Env, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(env.MEDIA_SIGN), { name: "HMAC", hash: "SHA-256" }, false, [usage]);
}

function ticketData(room: string, id: string, n: number, expires: number): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(`${room}.${id}.${n}.${expires}`);
}

/** The token that lets a device put [n] bytes under [id] until [expires] (server time, ms). */
export async function signTicket(env: Env, room: string, id: string, n: number, expires: number): Promise<string> {
  const key = await signingKey(env, "sign");
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, ticketData(room, id, n, expires))));
}

async function validTicket(env: Env, room: string, id: string, n: number, expires: number, token: string): Promise<boolean> {
  const signature = fromBase64url(token);
  if (!signature || !Number.isInteger(n) || !Number.isInteger(expires)) return false;
  // `verify` compares in constant time
  return crypto.subtle.verify("HMAC", await signingKey(env, "verify"), signature, ticketData(room, id, n, expires));
}

/** Puts a file in the bucket (with a ticket), or sends it back (to any member). */
export async function serveMedia(request: Request, env: Env, ctx: ExecutionContext, room: string, id: string): Promise<Response> {
  if (!env.MEDIA || !env.MEDIA_SIGN) return new Response("Pictures are not set up", { status: 404 });
  const key = mediaKey(room.toUpperCase(), id);

  if (request.method === "PUT") {
    const url = new URL(request.url);
    const n = Number(url.searchParams.get("n"));
    const expires = Number(url.searchParams.get("e"));
    const token = url.searchParams.get("token") ?? "";
    if (!(await validTicket(env, room.toUpperCase(), id, n, expires, token))) return new Response("Bad ticket", { status: 403 });
    if (expires < Date.now()) return new Response("Ticket expired", { status: 410 });
    // The bytes are counted by the header, which the platform holds the body to; the ticket says how many were paid for
    const length = Number(request.headers.get("Content-Length"));
    if (!Number.isInteger(length) || length < 1) return new Response("Length required", { status: 411 });
    if (length > n) return new Response("Too big", { status: 413 });
    await env.MEDIA.put(key, request.body, { httpMetadata: { contentType: "application/octet-stream" } });
    return new Response(null, { status: 204 });
  }

  if (request.method !== "GET") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, PUT" } });
  }
  // A file never changes under its id, so one that was fetched once is answered from the cache of the edge
  const cache = (caches as unknown as { default: Cache }).default;
  const cacheKey = new Request(new URL(`/media/${room.toUpperCase()}/${id}`, request.url).toString());
  const cached = await cache.match(cacheKey);
  if (cached) return cached;
  const object = await env.MEDIA.get(key);
  if (!object) return new Response("Not found", { status: 404 });
  const headers = new Headers({
    "Content-Type": "application/octet-stream",
    "Content-Length": String(object.size),
    ETag: object.httpEtag,
    "Cache-Control": "public, max-age=31536000, immutable",
  });
  const response = new Response(object.body, { headers });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}

/** What the files of all rooms take together: the one thing that must not pass what the free plan holds. */
export class MediaLedger extends DurableObject<Env> {
  /** Counts [n] bytes more if the total stays within [cap]; false if it would not. */
  async reserve(n: number, cap: number): Promise<boolean> {
    const used = (await this.ctx.storage.get<number>("bytes")) ?? 0;
    if (used + n > cap) return false;
    await this.ctx.storage.put("bytes", used + n);
    return true;
  }

  async release(n: number): Promise<void> {
    const used = (await this.ctx.storage.get<number>("bytes")) ?? 0;
    await this.ctx.storage.put("bytes", Math.max(0, used - n));
  }

  async used(): Promise<number> {
    return (await this.ctx.storage.get<number>("bytes")) ?? 0;
  }
}
