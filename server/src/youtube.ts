/**
 * YouTube Music for browsers. A page cannot ask `music.youtube.com` itself (no CORS), and the app on a phone does not
 * need this: it asks directly. So the web app asks here, and the Worker asks YouTube Music in its name.
 *
 * It is not an open proxy: it needs the room key like every other route, takes only the four endpoints the app reads,
 * only POST, only a small JSON body, and always asks the one host with a fixed address.
 */

/** The endpoints of `youtubei/v1` that `MusicClient` uses. */
export const YOUTUBE_ROUTE = /^\/yt\/(browse|search|next|music\/get_search_suggestions)$/;

const HOST = "https://music.youtube.com/youtubei/v1";

/** The same browser name the apps give, so that YouTube sees one kind of caller. */
const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; rv:128.0) Gecko/20100101 Firefox/128.0";

/** A request of the app is a few hundred bytes (a query, a token); anything near this is not one. */
export const MAX_BODY_BYTES = 8 * 1024;

export async function serveYoutube(request: Request, endpoint: string): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  }
  const body = await request.text();
  if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) {
    return new Response("Request too large", { status: 413 });
  }
  try {
    JSON.parse(body);
  } catch {
    return new Response("Body is not JSON", { status: 400 });
  }

  let reply: Response;
  try {
    reply = await fetch(`${HOST}/${endpoint}?prettyPrint=false`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: "https://music.youtube.com", "User-Agent": USER_AGENT },
      body,
    });
  } catch {
    return new Response("YouTube Music cannot be reached", { status: 502 });
  }
  if (!reply.ok) {
    // The app tells "YouTube Music said no" from "the server is down" by the status
    return new Response(`YouTube Music answered ${reply.status}`, { status: 502 });
  }
  return new Response(reply.body, {
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}
