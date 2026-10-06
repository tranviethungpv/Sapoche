# Sapoche server

A Cloudflare Worker plus one Durable Object per room. It only keeps metadata (queue, playback state, members), never audio.

- `src/index.ts`: routing (`GET /health`, `POST /rooms`, `WS /room/<CODE>`, `GET /room/<CODE>/info`, `GET /join/<CODE>`, `GET /.well-known/assetlinks.json`, `GET /update/latest.json`, `GET /update/app-<version>.apk`) and the shared-key check.
- `src/update.ts`: updates for the app itself, read from the R2 bucket `sapoche-releases` (private, only readable through the Worker, needs the key). Publish a new version with `app/tool/release.sh` (`--publish` uploads it to R2).
- `src/room.ts`: the room logic (preparation barrier, play, pause, seek, queue, owner and permissions, cleanup of empty rooms and dead sockets).
- `src/join-page.ts`: the HTML page of the invitation link and the list of signing keys for `assetlinks.json` (add a new key here when the signing key changes).
- `src/protocol.ts`: message types, matching [../docs/PROTOCOL.md](../docs/PROTOCOL.md).
- `scripts/sim.mjs`: simulates several devices and checks the whole protocol flow.
- `scripts/sim-keyed.mjs`: starts two local servers with a key (one with real timers, one with timers of a few seconds to watch a room expire), runs `sim.mjs`, then cleans up the processes (this is `npm test`).

## Running locally (no Cloudflare account needed)

Wrangler needs Node 22 or newer.

```bash
cd server
npm install
npm run typecheck
npm run dev          # http://127.0.0.1:8787
npm run sim          # in another terminal, against the server without a key; expect 39 passed
npm test             # starts a server with a key and tests it; expect 147 passed, then 6 passed, 0 failed
```

For a phone on the same Wi-Fi to connect, run `npx wrangler dev --ip 0.0.0.0 --port 8787` and use `ws://<dev-machine-ip>:8787`.

## Deploying

The server is reachable at `https://<worker-name>.<account>.workers.dev` (WebSocket: `wss://.../room/<CODE>`).

```bash
npx wrangler login        # once, opens the browser
npx wrangler r2 bucket create sapoche-releases   # once; the bucket must exist before deploying
npm run deploy
node scripts/sim.mjs https://<worker-name>.<account>.workers.dev   # test against the real server
```

To try the WebSocket with curl add `--http1.1` (HTTP/2 has no Upgrade header).

## The shared key (secret)

Without a key, anyone who knows the URL could create rooms and use up the Free plan's 100,000 requests per day. The Worker therefore requires the key `ROOM_KEY` for `POST /rooms` and `WS /room/<CODE>`; a wrong or missing key gets a 401. `/health` is always open, to tell "server broken" from "wrong key". The key is sent in the `X-Sapoche-Key` header (the app) or the `?key=` parameter (clients that cannot set headers, such as a browser). If the server has no `ROOM_KEY` (running locally) it is completely open.

```bash
# set or change the key (a generated value, never stored in Git)
openssl rand -hex 16 | tr -d '\n' | npx wrangler secret put ROOM_KEY
```

The Android app reads the key at build time from `app/android/sapoche.properties` (already in `.gitignore`):

```properties
sapoche.roomKey=<key>
sapoche.serverUrl=https://<worker-name>.<account>.workers.dev
```

Changing the key means building and reinstalling the app for the whole group. The key is inside the APK, so it only keeps strangers out, not people in the group.

## Operations

- Live log: `npx wrangler tail`.
- An empty room that still has songs is deleted after 7 days, an empty room without songs after 1 hour; a room holds at most 12 people and 200 songs, and each connection at most 20 messages per second. A room takes less than 50 KB (the free plan gives 5 GB in total), so an orphaned room costs nothing; the cleanup is there to keep the "recent rooms" list honest.
- Environment variables meant for tests only (`STALE_MS`, `DROP_MS`, `SWEEP_MS`, `EMPTY_MS`, `EMPTY_BARE_MS`) shorten the timers above; do not set them on a real server.
- Load estimate: a device sends about 2 pings a minute (to measure the clock) and a few messages per song, and writes to storage about 10 times per song, so a group of 5 listening all day stays far below the limit of 100,000 requests and 100,000 writes per day (WebSocket messages count 20 to 1 request).
- Current protocol version: 10 (`GET /health` reports `protocol`, and the `state` message carries it too). Every change so far only added things, so an older app still works; a client sends pictures only to a server that says it is on 8 or newer, shows the room's autoplay only once the state carries it (9 or newer), and shows the chat and reactions only once the room has sent its chat history (10 or newer).
