import { ASSET_LINKS, joinPage } from "./join-page";
import { PROTOCOL_VERSION } from "./protocol";
import { Room } from "./room";

export { Room };

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
  const given = request.headers.get("X-Unison-Key") ?? url.searchParams.get("key") ?? "";
  return sameSecret(given, env.ROOM_KEY);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Open on purpose: lets a phone tell "server down" from "wrong key"
    if (url.pathname === "/health") return Response.json({ ok: true, protocol: PROTOCOL_VERSION });

    // Open too: an invitation link is followed before the app can send its key, and reveals nothing about a room
    const join = url.pathname.match(/^\/join\/([A-Za-z0-9]{6})$/);
    if (join) {
      return new Response(joinPage(join[1].toUpperCase()), {
        headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=3600" },
      });
    }
    if (url.pathname === "/.well-known/assetlinks.json") {
      return Response.json(ASSET_LINKS, { headers: { "Cache-Control": "public, max-age=3600" } });
    }

    const isRoomRoute = url.pathname === "/rooms" || ROOM_ROUTE.test(url.pathname);
    if (isRoomRoute && !(await authorized(request, url, env))) {
      return new Response("Unauthorized", { status: 401 });
    }

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
