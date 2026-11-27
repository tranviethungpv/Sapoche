import { Connect, CONNECT_ROUTE, CONNECT_VERSION } from "./connect";
import { ASSET_LINKS, joinPage, pageLanguage } from "./join-page";
import { LASTFM_ROUTE, serveLastFm } from "./lastfm";
import { PROTOCOL_VERSION } from "./protocol";
import { MEDIA_ROUTE, MediaLedger, serveMedia } from "./media";
import { Room } from "./room";
import { serveSync, SYNC_ROUTE } from "./sync";
import { serveUpdate, UPDATE_ROUTE } from "./update";
import { serveYoutube, YOUTUBE_ROUTE } from "./youtube";

export { Connect, MediaLedger, Room };

// No 0/O/1/I/L: room codes are read out loud and typed on phones
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;

/** A room's WebSocket, or its `/info` summary. */
const ROOM_ROUTE = /^\/room\/([A-Za-z0-9]{6})(?:\/info)?$/;

function newRoomCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  return Array.from(bytes, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

/** Compares two secrets without leaking, through timing, how much of a guess was right. */
async function sameSecret(given: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/**
 * The key comes in a header (apps) or a `key` query parameter (WebSocket clients that cannot set
 * headers, such as browsers). Without a configured key everything is allowed.
 */
async function authorized(request: Request, url: URL, env: Env): Promise<boolean> {
  if (!env.ROOM_KEY) return true;
  const given = request.headers.get("X-Sapoche-Key") ?? url.searchParams.get("key") ?? "";
  return sameSecret(given, env.ROOM_KEY);
}

/**
 * Whether this address has asked for [route] too often. The count is Cloudflare's, kept per location, and only rough.
 * Without the binding, or without an address from the edge, nothing is limited; `wrangler dev` names the machine itself
 * (127.0.0.1), and the simulations create rooms faster than a person ever would, so that address is let through too.
 */
async function tooOften(limiter: RateLimit | undefined, request: Request, route: string): Promise<boolean> {
  const address = request.headers.get("CF-Connecting-IP");
  if (!limiter || !address || address === "127.0.0.1" || address === "::1") return false;
  return !(await limiter.limit({ key: `${route}:${address}` })).success;
}

const slowDown = () => new Response("Too many requests", { status: 429, headers: { "Retry-After": "60" } });

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // Open on purpose: lets a phone tell "server down" from "wrong key"
    if (url.pathname === "/health") return Response.json({ ok: true, protocol: PROTOCOL_VERSION, connect: CONNECT_VERSION });

    // Open too: an invitation link is followed before the app can send its key, and reveals nothing about a room
    const join = url.pathname.match(/^\/join\/([A-Za-z0-9]{6})$/);
    if (join) {
      const language = pageLanguage(request.headers.get("Accept-Language"));
      return new Response(joinPage(join[1].toUpperCase(), language), {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "public, max-age=3600",
          // One address, two pages: a cache must not hand one language to a reader of the other
          Vary: "Accept-Language",
        },
      });
    }
    if (url.pathname === "/.well-known/assetlinks.json") {
      return Response.json(ASSET_LINKS, { headers: { "Cache-Control": "public, max-age=3600" } });
    }

    const pushKey = url.pathname === "/push/key";
    const update = url.pathname.match(UPDATE_ROUTE);
    const youtube = url.pathname.match(YOUTUBE_ROUTE);
    const media = url.pathname.match(MEDIA_ROUTE);
    const lastfm = url.pathname === LASTFM_ROUTE;
    const sync = url.pathname.match(SYNC_ROUTE);
    const connect = url.pathname.match(CONNECT_ROUTE);
    const isRoomRoute = url.pathname === "/rooms" || ROOM_ROUTE.test(url.pathname);
    if ((isRoomRoute || update || youtube || media || pushKey || lastfm || sync || connect) && !(await authorized(request, url, env))) {
      return new Response("Unauthorized", { status: 401 });
    }

    // After the key, so that a wrong key is told so as before; a stranger without it never costs a count
    if (youtube && (await tooOften(env.LIMIT_YT, request, "yt"))) return slowDown();
    if (lastfm && (await tooOften(env.LIMIT_LASTFM, request, "lastfm"))) return slowDown();
    if (sync && (await tooOften(env.LIMIT_SYNC, request, "sync"))) return slowDown();
    if (connect && (await tooOften(env.LIMIT_CONNECT, request, "connect"))) return slowDown();
    if (request.method === "POST" && url.pathname === "/rooms" && (await tooOften(env.LIMIT_ROOMS, request, "rooms"))) return slowDown();
    if (ROOM_ROUTE.test(url.pathname) && (await tooOften(env.LIMIT_JOIN, request, "join"))) return slowDown();

    // The public half of the key that signs pushes: a browser needs it to ask for them
    if (pushKey) return env.VAPID_PUBLIC ? Response.json({ key: env.VAPID_PUBLIC }) : new Response("Not found", { status: 404 });
    if (update) return serveUpdate(request, env, update[1]);
    if (youtube) return serveYoutube(request, youtube[1]);
    if (lastfm) return serveLastFm(request, env);
    if (sync) return serveSync(request, env, sync);
    if (connect) return env.CONNECT.get(env.CONNECT.idFromName(connect[1])).fetch(request);
    if (media) return serveMedia(request, env, ctx, media[1], media[2]);

    // Room codes are only a namespace: the Durable Object is created lazily on first connection
    if (request.method === "POST" && url.pathname === "/rooms") {
      return Response.json({ code: newRoomCode() });
    }

    const match = url.pathname.match(ROOM_ROUTE);
    if (match) {
      const id = env.ROOMS.idFromName(match[1].toUpperCase());
      return env.ROOMS.get(id).fetch(request);
    }

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
