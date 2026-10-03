# Sapoche: sync protocol (draft v0)

Connection: a WebSocket to `wss://<worker>/room/<CODE>`. Every room is a Durable Object. Messages are JSON with a field `t` (type).

## 1. Room state (the server is the source of truth)

```json
{
  "queue": [{ "id": "q1", "videoId": "dQw4w9WgXcQ", "title": "...", "artist": "...", "thumb": "...", "durMs": 213000, "addedBy": "u2" }],
  "index": 0,
  "phase": "idle | preparing | playing | paused",
  "startedAt": 1759140000000,
  "positionMs": 0,
  "epoch": 17,
  "repeat": "off | all | one",
  "name": "Family",
  "ownerId": "u1",
  "guestControl": "all | add",
  "members": [{ "id": "u1", "name": "Ann", "ready": true, "solo": false, "away": false, "owner": true, "av": "3fa9c01e" }]
}
```

`name` and `ownerId` may be absent. See section 5c for the owner and the room name. `av` is the fingerprint of the member's picture and is absent when they have none; see section 5d.

- `phase=playing`: the current position is `serverNow - startedAt`.
- `phase=paused`: the position is `positionMs`.
- `epoch` increases whenever a change makes the old state obsolete (song change, seek, play/pause). Clients ignore messages with an old `epoch`.

## 2. Measuring the clock offset (simple NTP)

The client sends `{t:"ping", c0}` (c0 = the client's clock). The server answers `{t:"pong", c0, s1}` (s1 = the server's clock). When the client receives it at c2:
- `rtt = c2 - c0`
- `offset = s1 - (c0 + rtt/2)` (server time ≈ local time + offset)

It measures 8 times when joining and keeps the sample with the smallest `rtt`. It measures again every 30 seconds while the screen is on, and every few minutes in the background.

## 2b. Authentication

`POST /rooms`, `GET /room/<CODE>/info` and `WS /room/<CODE>` need the shared key `ROOM_KEY` (header `X-Sapoche-Key`, or the parameter `?key=` where no header can be set). A wrong or missing key gets HTTP 401 before the WebSocket upgrade; the client treats that as a final error and does not retry. Three routes are always open: `GET /health` returns `{"ok":true,"protocol":8}`; `GET /join/<CODE>` is the page an invitation link opens (it tries to open the app with `intent://`, and otherwise shows the code); `GET /.well-known/assetlinks.json` lets Android verify the app's https links. These three do not touch any room, so they need no key. Operational details are in [../server/README.md](../server/README.md).

`GET /room/<CODE>/info` is read-only and creates nothing: `{"exists":true,"name":"Family","members":2,"playing":true,"title":"..."}`; `exists:false` when the room never existed or has expired. The app uses it for the list of recent rooms.

## 3. Messages client → server

| `t` | Fields | Meaning |
|---|---|---|
| `join` | `name`, `clientId`, `create?` | Join a room; the server answers with `state`. `create:true` is a code the device just made up, `create:false` is a code it was given: if the room does not exist the server answers with the error `room_not_found` and closes with 4004 (a mistyped code does not open an empty room). A missing `create` is an old app, which is allowed to open the room as before |
| `bye` | | Leave on purpose (as opposed to losing the connection). When the owner sends `bye` the longest-present member becomes the owner; a room with nobody left has no owner |
| `kick` | `id` | Owner only: disconnect that member (closes 4001, with the error `removed`); they can join again |
| `room.name` | `name` | Rename the room, at most 32 characters, empty removes the name |
| `room.settings` | `guestControl` | Owner only: `all` (everybody steers, the default) or `add` (guests can only add songs) |
| `ping` | `c0` | Clock measurement |
| `avatar.set` | `data` | The device's own picture: base64 of a small JPEG or PNG (about 256 px), at most 24,000 characters; `null` takes it away. Anything else is ignored. Only servers of protocol 8 or newer know it, and an older one answers with `unknown_type`, so a client sends it only after a `state` that says `protocol` 8 or more |
| `avatar.get` | `id` | Asks for the picture of the member `id`; answered with `avatar` to this socket only |
| `queue.add` | `videoId`, metadata, `next?` | Add a song; `next: true` inserts it right after the current one (if the room is `idle` the new song is only appended and played) |
| `queue.addMany` | `tracks[]`, `next?` | Add several songs at once (a playlist), at most 100 per message, songs with a bad `videoId` are dropped; the same `next` rule as `queue.add`. One message and one `state` broadcast, so it does not run into the limit of 20 messages per second |
| `queue.remove` | `id` | Remove a song |
| `queue.swap` | `id`, `track` (`videoId`, `title`, `artist`, `thumb?`, `durMs`) | Replace the entry `id` with another release of the same song (video ↔ audio), keeping its place, its `id` and who added it. If it is the song being played (running, paused or preparing): broadcast a new `prepare` to every device, seek to exactly the current position (clipped to the length of the new release), then `start` once everybody is ready; a paused room plays on after the swap. A `videoId` equal to an existing one or an unknown `id` is ignored; a bad `videoId` gives `bad_video`. Restricted like `queue.move` when the owner lets guests only add songs. Protocol 7 |
| `queue.clear` | | Clear the whole queue, the room goes `idle` |
| `queue.shuffle` | | Shuffle the **upcoming** songs, the current one keeps its place. When the room is `idle` (the queue has run out) it shuffles everything and plays from the first song. With fewer than 2 songs it does nothing |
| `jump` | `id` | Play this song from the start now (through the barrier) |
| `queue.move` | `id`, `toIndex` | Change the position |
| `play` / `pause` | | Control. `play` when the room is `idle` at the last song (the queue has run out) plays again **from the first song**, not only the last one |
| `seek` | `positionMs` | Seek |
| `next` / `prev` | | Change song; `next` at the last song with `repeat=all` goes back to the first |
| `repeat` | `mode` | `off`: stop after the last song. `all`: when the queue ends, play it again from the start. `one`: when the current song ends, play it again (the `next` button still goes to the next song). Unknown values are ignored |
| `solo` | `on` | Start (`true`) or stop (`false`) listening alone: the room's commands no longer steer this device and the room does not wait for it at the barrier. The server forgets this flag when the socket drops, so the client sends it again after every reconnect |
| `resync` | | Ask the server to send `state` again (and `prepare` if the room is preparing) to this socket only; used when coming back to the room after listening alone |
| `ready` | `epoch` | The device has resolved the stream and buffered enough, ready to play |
| `report` | `epoch`, `posMs`, `bufferMs` | Periodic position report (diagnostics only, every 10 seconds) |
| `resolveFailed` | `epoch`, `reason` | The device could not get the stream. It counts as answered, so it does not hold the others back; if **every** device in the room reports a failure the server sends an `error` with code `unplayable` and moves on to the next song (or `idle` if there are none) instead of running a silent clock |
| `ended` | `epoch` | The song ended with no preloaded song after it (the last song, or the preload failed) |
| `advanced` | `epoch`, `itemId`, `startedAt` | The device moved to the preloaded next song by itself; `startedAt` is the server time at which it heard position 0 of the new song |

## 4. Messages server → client

| `t` | Fields | Meaning |
|---|---|---|
| `state` | the whole state, `protocol` | Sent on joining and on big changes; `protocol` is the server's protocol version (currently 8) |
| `prepare` | `epoch`, song, `seekToMs`, `by?` | Prepare the song: resolve, buffer, then send `ready`. `by` is the `clientId` of whoever just changed the song; absent when the room moves on by itself |
| `start` | `epoch`, `startAt` (server time), `by?` | Start playing at this moment |
| `pause` | `epoch`, `positionMs`, `by?` | Stop at the position |
| `advance` | `epoch`, `index`, `startedAt` | The whole room moves to the next song without the barrier, position 0 heard at `startedAt` |
| `pong` | `c0`, `s1` | Answer to a ping |
| `avatar` | `id`, `av?`, `data?` | The picture of `id` and its fingerprint; both absent when that member has none |
| `members` | `members[]` | The member list, sent when someone joins, leaves, renames, changes solo mode, the owner changes, or someone switches between present and `away` |
| `error` | `code`, `message` | Codes today: `not_joined`, `bad_message`, `bad_json`, `rate_limited`, `unknown_type`, `bad_video`, `queue_full`, `unplayable`, `room_not_found` (with close 4004), `room_full` (with close 1008), `forbidden` (a command only the owner may give), `removed` (with close 4001) |

## 5. Changing song (the barrier)

1. A device sends `next` (or the current song ends).
2. The server increases `epoch`, sets `phase=preparing` and sends `prepare` to every device.
3. Every device resolves the URL, buffers about 3 seconds and sends `ready`.
4. When every device is `ready` (or after 8 seconds, skipping the slow ones) the server sets `startedAt = serverNow + 1500ms` and `phase=playing`, and sends `start`.
5. Every device converts `startAt` to its own clock (minus `offset`) and starts playing at exactly that moment.
6. A device that was skipped because it was late to be ready seeks to the current position and plays.
7. While playing, every device resolves and preloads the next song so the change is seamless.

### Seamless change (gapless)

A natural change does not go through the barrier, so there is no silence:

1. While following the room, every client hands the player `queue[index+1]` as the next song (ExoPlayer buffers it and joins it seamlessly). If the list changes, the next song is replaced accordingly.
2. When the player moves to the next song by itself, the client waits about 1 second for the position to settle and sends `advanced` with `startedAt = server time - the position being heard`.
3. The server takes the first valid report (the right `epoch`, the right `itemId` being the next song, a timestamp not more than 10 seconds old, the current song having at most 15 seconds left), increases `epoch` and `index`, sets `startedAt`, and sends `advance` to every device. Later reports are ignored because the `epoch` is already old.
4. A device that has already changed song takes the new time origin and goes on correcting drift. A device about to change waits for its own player (at most 4 seconds). A device with nothing preloaded loads like a late joiner.
5. If no device reports `advanced`, the old path still runs: `ended` or the end-of-song alarm (length + 5 seconds) leads to `prepare` and the barrier.

### Repeat

Repeat does not take the gapless path: when the song ends the client reports `ended` (or the end-of-song alarm runs), and the server calls `begin` again on that same song (`repeat=one`) or on the first song (`repeat=all` at the end of the queue), so there is one barrier beat of about 1.5 to 4 seconds between two rounds. With `repeat=one` the client does not preload the next song (otherwise ExoPlayer would move to it by itself) and the server ignores `advanced`.

## 5b. Listening alone and presence

**Listening alone (`solo`).** A device can stop following the room without leaving it. It keeps the song it is playing; from then on the room's `prepare`, `start`, `pause` and `advance` only update what is shown (the room is paused, which song it is on), while the play, pause, seek, next, previous and pick-a-song controls act on this device only, follow the room's queue and preload the next song so there is no gap when a song ends. A device listening alone does not send `ready`, `ended` or `advanced`, so it never holds the room back. To come back: send `solo:false` then `resync`, and handle the `state` that comes back like a late joiner (on the same song it only re-aligns the position, without reloading).

Who did what: `pause`, `start` and `prepare` carry `by` so that other devices can show "Ann paused the room" with a "Keep playing" button (switch to listening alone and carry on) or "Ann skipped to X".

**Presence (`away`).** The client sends `ping` every 30 seconds (every ping keeps the mobile radio awake, so sparser is better for battery), and the server records the last time it heard each socket. A member that is silent for more than 75 seconds is marked `away` (dimmed, not counted as listening, does not hold the barrier); after more than 150 seconds the server closes the socket and removes it from the list. Every message from anybody is a chance for the server to check and to broadcast `members` again if someone changed status, so no separate timer is needed. This is a fallback for a socket that died without closing; an app that was force-stopped is usually noticed at once when its socket closes.

## 5c. Owner, room name and lifecycle

**Owner.** Whoever opens the room (`create:true`), or the first to join when the room has no owner, is the owner. `guestControl` defaults to `all`: everybody has equal rights, as before. When the owner switches to `add`, guests can only add songs (`queue.add`, `queue.addMany`) and listen alone; `play`, `pause`, `seek`, `next`, `prev`, `jump`, `queue.remove`, `queue.swap`, `queue.move`, `queue.clear`, `queue.shuffle`, `repeat` and `room.name` get `forbidden`. The limit only holds while the owner is present (socket open and not `away`); if the owner loses the connection everybody can steer, and when the owner is back the limit is back, with no handover timer. `kick` and `room.settings` are always owner-only. A room with nobody left loses its owner and `guestControl` goes back to `all`; the first to join afterwards becomes the new owner.

**Lifecycle.** A code is only a name: a room is born when someone joins with `create` not equal to `false`, and does not exist before that. An empty room is kept for 7 days if there are songs left in its queue, for 1 hour if there are none, and then deleted entirely (`deleteAll`). The server has only one Durable Object alarm but keeps the due time of each job (`barrier`, `end`, `gc`, `sweep`) and sets the alarm at the nearest one. `sweep` runs every 5 minutes while the room has people: it closes sockets that have been silent for more than 150 seconds (even when nobody sends anything), so a room of dead devices still becomes empty and is cleaned up. A socket that has not joined (or was refused) creates no data. The server also understands the state stored in the old form (a single alarm).

## 5d. Pictures

A member's picture is not part of the member list: that list is sent whenever somebody is ready, away or solo, and a picture in it would be sent many times a song. Instead the list carries `av`, a fingerprint of 8 hexadecimal digits (the start of the SHA-256 of the picture's text). A client keeps the fingerprint it last fetched for each member and sends `avatar.get` only for a member whose `av` is new or changed, and drops what it holds for a member who has no `av` any more or who is gone.

The server keeps the pictures in storage, one per client id (a socket attachment holds only 2 KiB), and drops those of members who are no longer here. A device sends `avatar.set` once per connection, right after the first `state`; a device that comes back within the lifetime of the room keeps the picture it had, so it does not disappear from the others' screens for the moment of a reconnect. Setting the same picture again changes nothing for the others.

## 6. Correcting drift while playing

Every 500 ms the client computes `drift = playerPosition - expectedPosition`:

| `|drift|` | Action |
|---|---|
| < 40 ms | Keep speed 1.0 |
| 40 ms to 400 ms | Set the speed to 0.97 or 1.03 until it gets close to 0 |
| > 400 ms | `seekTo(expectedPosition)`; if seeks keep failing, report an error |

The thresholds are starting values, to be tuned after measuring on real devices.

Measurements on a real phone show that the position ExoPlayer reports has a sawtooth noise of about 200 ms with a period of 3 to 4 seconds, so decisions are not based on single samples but on the **average over a window of 8 samples (4 seconds)**, after subtracting what was corrected by changing speed. The window is cleared after every seek and every time the player stops or buffers.

**Start latency.** Every device is heard about 150 to 350 ms later than asked after `play()` or a seek (audio output latency). The device learns it: after every normal start, the drift left in the first full window is added to `startBias` (factor 0.8, limited to ±800 ms, kept in the device's storage), and the next time it seeks ahead by exactly that amount. There is also a `trim` that the person sets by hand for devices with an unusual latency (a Bluetooth speaker).

## 7. Recovery

- WebSocket dropped: the client reconnects by itself (backoff 1 s, 2 s, 4 s, at most 15 s), joins again with `join` and the same `clientId`, receives a new `state` and syncs again. When Android reports that the network is back or changed, the wait is skipped and it reconnects at once.
- Rejoining a room that is playing the very song already loaded does not reload it: it only re-aligns to the room's time origin (and presses play if the device is paused).
- A repeated `prepare` with the same `epoch` for a device that has finished loading: it only sends `ready` again.
- Losing the network mid-song: the player retries network errors for up to about 8 minutes and carries on from its buffer; only a URL that is refused (401, 403, 404, 410) reports an error at once so that it is loaded again with a fresh URL. If loading again fails (no network yet) it retries every 5 seconds.
- The process is killed by the system: the app stores the room code, the last time it was alive (written every minute while in a room) and the solo mode. If the service restarts within 10 minutes it rejoins the room (`join` with `create:false`), and if it was listening alone it rejoins in solo mode, paused, without playing by itself. After 10 minutes, or when the app is opened normally, it starts outside a room with the personal queue.
- A long pause: in a room, not playing and with the screen not shown for more than 20 minutes, the client closes the WebSocket (a ping every 30 seconds keeps the radio awake all day); it reconnects when the screen is shown or when a command arrives from the notification (the command is held until the connection is up). The server sees a member leaving, and the room lets everybody steer if that member was the owner.
- A connection that died without closing: the client uses exactly one ping (30 seconds) and treats the connection as dead if there is no `pong` for 45 seconds, then reconnects; there is no OkHttp protocol-level ping any more.
- The device stops by itself (a call, another app taking the audio) while the room is playing: the play button only resumes on that device, the room is not restarted; a large drift is handled with one seek.
- The Durable Object sleeps (Hibernation): the state is in storage and is not lost when it wakes up.
- Messages with an old `epoch` are ignored.

## 8. Open points (to verify by measuring)

- Whether the 1500 ms start delay is enough for slow devices.
- Whether the drift thresholds and the speed correction make the sound distort.
- How to handle two people pressing controls at the same time (today: the message that reaches the server first wins).
