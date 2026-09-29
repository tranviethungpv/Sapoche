import { Room } from "./room";

export { Room };

// No 0/O/1/I/L: room codes are read out loud and typed on phones
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;

function newRoomCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  return Array.from(bytes, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") return new Response("ok");

    // Room codes are only a namespace: the Durable Object is created lazily on first connection
    if (request.method === "POST" && url.pathname === "/rooms") {
      return Response.json({ code: newRoomCode() });
    }

    const match = url.pathname.match(/^\/room\/([A-Za-z0-9]{6})$/);
    if (match) {
      const id = env.ROOMS.idFromName(match[1].toUpperCase());
      return env.ROOMS.get(id).fetch(request);
    }

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
