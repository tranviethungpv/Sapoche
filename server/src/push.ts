// Web Push from a Worker: a message is encrypted for the browser that asked for it (RFC 8291, aes128gcm) and signed
// with this server's own VAPID key (RFC 8292), then handed to the push service of that browser (RFC 8030). It is all
// WebCrypto; the libraries for this are written for Node and do not run here.

/** What a browser gives when it subscribes (`PushSubscription.toJSON()`). */
export interface WebPushSubscription {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

/** The push services of the browsers: Chrome and Edge (Google), Firefox, Safari, and Edge's older Windows one. */
const PUSH_HOSTS = [/\.googleapis\.com$/, /\.push\.services\.mozilla\.com$/, /\.push\.apple\.com$/, /\.notify\.windows\.com$/];

/** Most characters of an endpoint that are taken; real ones are about 200 to 500. */
const MAX_ENDPOINT_CHARS = 1000;

/** How long a push service keeps a message for a browser that is off, in seconds. */
const TTL_SECONDS = 3600;

/** A record holds this many bytes; a message is always one record. */
const RECORD_SIZE = 4096;

/** What the keys of the server are, as `wrangler secret put` stores them (base64url). */
export interface VapidKeys {
  /** The private key: 32 bytes. */
  privateKey: string;
  /** The public key: 65 bytes, the uncompressed point. */
  publicKey: string;
  /** Who runs this server, as a push service asks to know: a `mailto:` or an `https:` address. */
  subject: string;
}

/** Bytes in a buffer of their own, which is what WebCrypto takes. */
type Bytes = Uint8Array<ArrayBuffer>;

const encoder = new TextEncoder();

export function b64urlEncode(bytes: Uint8Array): string {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(text: string): Bytes {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

function concat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/**
 * The subscription as the browser sent it when it is well formed, else null. An address that is not one of the push
 * services is refused: this server will POST to it, so it must not be made to call any address a client likes.
 * [allowLocal] lets the tests point it at a service on this machine.
 */
export function readSubscription(value: unknown, allowLocal = false): WebPushSubscription | null {
  if (typeof value !== "object" || value === null) return null;
  const { endpoint, keys } = value as { endpoint?: unknown; keys?: { p256dh?: unknown; auth?: unknown } };
  if (typeof endpoint !== "string" || endpoint.length > MAX_ENDPOINT_CHARS) return null;
  if (typeof keys?.p256dh !== "string" || typeof keys.auth !== "string") return null;
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return null;
  }
  const local = allowLocal && url.protocol === "http:" && url.hostname === "127.0.0.1";
  if (!local && (url.protocol !== "https:" || !PUSH_HOSTS.some((host) => host.test(url.hostname)))) return null;
  try {
    const point = b64urlDecode(keys.p256dh);
    if (point.length !== 65 || point[0] !== 4 || b64urlDecode(keys.auth).length !== 16) return null;
  } catch {
    return null;
  }
  return { endpoint, keys: { p256dh: keys.p256dh, auth: keys.auth } };
}

async function hkdf(salt: Bytes, secret: Bytes, info: Bytes, bytes: number): Promise<Bytes> {
  const key = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, bytes * 8));
}

/** What the sender picks at random; given, it makes the result the same every time, for the test of RFC 8291. */
export interface Randomness {
  salt: Bytes;
  keys: CryptoKeyPair;
}

/** The body of a push message: [plain] made unreadable to anyone but the browser that owns [userKey] and [auth]. */
export async function encryptPayload(
  plain: Bytes,
  userKey: Bytes,
  auth: Bytes,
  fixed?: Randomness,
): Promise<Bytes> {
  if (plain.length > RECORD_SIZE - 18) throw new Error("push message too long");
  const own = fixed?.keys ?? ((await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair);
  const ownPublic = new Uint8Array(await crypto.subtle.exportKey("raw", own.publicKey));
  const theirs = await crypto.subtle.importKey("raw", userKey, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: theirs }, own.privateKey, 256));
  const salt = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16));

  const secret = await hkdf(auth, shared, concat(encoder.encode("WebPush: info\0"), userKey, ownPublic), 32);
  const contentKey = await crypto.subtle.importKey("raw", await hkdf(salt, secret, encoder.encode("Content-Encoding: aes128gcm\0"), 16), "AES-GCM", false, ["encrypt"]);
  const nonce = await hkdf(salt, secret, encoder.encode("Content-Encoding: nonce\0"), 12);
  // The 2 after the text says that this is the last record
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, contentKey, concat(plain, Uint8Array.of(2))));

  const size = new Uint8Array(4);
  new DataView(size.buffer).setUint32(0, RECORD_SIZE);
  return concat(salt, size, Uint8Array.of(ownPublic.length), ownPublic, sealed);
}

/** The `Authorization` header that tells a push service which server sends: a signed claim for its own address. */
async function vapidAuthorization(endpoint: string, vapid: VapidKeys): Promise<string> {
  const point = b64urlDecode(vapid.publicKey);
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", x: b64urlEncode(point.slice(1, 33)), y: b64urlEncode(point.slice(33)), d: vapid.privateKey },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const claim = { aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: vapid.subject };
  const text = `${b64urlEncode(encoder.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })))}.${b64urlEncode(encoder.encode(JSON.stringify(claim)))}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(text)));
  return `vapid t=${text}.${b64urlEncode(signature)}, k=${vapid.publicKey}`;
}

/**
 * Sends [message] to the browser that holds [sub]. The answer of the push service: 201 when it took the message, 404
 * or 410 when that browser no longer exists, 0 when the service could not be reached.
 */
export async function sendWebPush(sub: WebPushSubscription, message: unknown, vapid: VapidKeys): Promise<number> {
  try {
    const body = await encryptPayload(encoder.encode(JSON.stringify(message)), b64urlDecode(sub.keys.p256dh), b64urlDecode(sub.keys.auth));
    const reply = await fetch(sub.endpoint, {
      method: "POST",
      headers: {
        Authorization: await vapidAuthorization(sub.endpoint, vapid),
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        TTL: String(TTL_SECONDS),
        Urgency: "high",
      },
      body,
    });
    await reply.body?.cancel();
    return reply.status;
  } catch {
    return 0;
  }
}
