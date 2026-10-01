/**
 * Updates for the app itself. The APK holds the room key, so it is kept in a private R2 bucket and only
 * handed to callers that present that key (see `authorized` in index.ts). Nothing here can write to the
 * bucket: releases are put there from a computer with `app/tool/release.sh`.
 *
 * The bucket holds `latest.json` and one `app-<versionCode>.apk` per release; old ones stay, so going back
 * is a matter of publishing an older `latest.json`.
 */

/** What `latest.json` must say; the app checks it again before installing. */
export interface LatestRelease {
  versionCode: number;
  versionName: string;
  sha256: string;
  size: number;
  notes?: string;
}

export const UPDATE_ROUTE = /^\/update\/(latest\.json|app-\d{1,9}\.apk)$/;

/** Serves one of the two kinds of file, with `Range` so that an interrupted download can go on. */
export async function serveUpdate(request: Request, env: Env, name: string): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  if (!env.RELEASES) return new Response("Updates are not set up", { status: 404 });

  const object = await env.RELEASES.get(name, {
    range: request.headers,
    onlyIf: request.headers,
  });
  if (!object) return new Response("Not found", { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  // The answer about which version is newest must never be a stale one
  headers.set("Cache-Control", name === "latest.json" ? "no-cache" : "private, max-age=3600");
  if (name === "latest.json") headers.set("Content-Type", "application/json; charset=utf-8");
  else headers.set("Content-Type", "application/vnd.android.package-archive");

  // The conditional request matched: there is no body to send
  if (!("body" in object)) return new Response(null, { status: 304, headers });

  // R2 reports a range even when none was asked for (the whole file), which must stay a plain 200
  const range = request.headers.has("Range") && object.range && "offset" in object.range ? object.range : undefined;
  if (range) {
    const length = range.length ?? object.size - (range.offset ?? 0);
    const start = range.offset ?? 0;
    headers.set("Content-Range", `bytes ${start}-${start + length - 1}/${object.size}`);
    headers.set("Content-Length", String(length));
  } else {
    headers.set("Content-Length", String(object.size));
  }
  return new Response(request.method === "HEAD" ? null : object.body, { status: range ? 206 : 200, headers });
}
