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
  "autoplay": true,
  "shuffle": false,
  "members": [{ "id": "u1", "name": "Ann", "ready": true, "solo": false, "away": false, "owner": true, "av": "3fa9c01e" }]
}
```

`name` and `ownerId` may be absent. See section 5c for the owner and the room name. Member ids, `ownerId`, `addedBy`, `by` and `you` are **public ids**, never the `clientId` a device joins with (section 3). `autoplay` says whether the room carries on by itself when its queue runs out (section 5e); it is absent when the server is older than protocol 9. `shuffle` says whether shuffle is on (section 5g); it is absent when the server is older than protocol 11. `av` is the fingerprint of the member's picture and is absent when they have none; see section 5d.

- `phase=playing`: the current position is `serverNow - startedAt`.
- `phase=paused`: the position is `positionMs`.
- `epoch` increases whenever a change makes the old state obsolete (song change, seek, play/pause). Clients ignore messages with an old `epoch`.

## 2. Measuring the clock offset (simple NTP)

The client sends `{t:"ping", c0}` (c0 = the client's clock). The server answers `{t:"pong", c0, s1}` (s1 = the server's clock). When the client receives it at c2:
- `rtt = c2 - c0`
- `offset = s1 - (c0 + rtt/2)` (server time ≈ local time + offset)

It measures 8 times when joining and keeps the sample with the smallest `rtt`. It measures again every 30 seconds while the screen is on, and every few minutes in the background.

## 2b. Authentication

`POST /rooms`, `GET /room/<CODE>/info` and `WS /room/<CODE>` need the shared key `ROOM_KEY` (header `X-Sapoche-Key`, or the parameter `?key=` where no header can be set). A wrong or missing key gets HTTP 401 before the WebSocket upgrade; the client treats that as a final error and does not retry. Three routes are always open: `GET /health` returns `{"ok":true,"protocol":11}`; `GET /join/<CODE>` is the page an invitation link opens (it tries to open the app with `intent://`, and otherwise shows the code); `GET /.well-known/assetlinks.json` lets Android verify the app's https links. These three do not touch any room, so they need no key. Operational details are in [../server/README.md](../server/README.md).

`GET /room/<CODE>/info` is read-only and creates nothing: `{"exists":true,"name":"Family","members":2,"playing":true,"title":"..."}`; `exists:false` when the room never existed or has expired. The app uses it for the list of recent rooms.

## 3. Messages client → server

| `t` | Fields | Meaning |
|---|---|---|
| `join` | `name`, `clientId`, `create?` | Join a room; the server answers with `state`. `clientId` is the device's own secret: the room knows the device by its public id, the first 16 hexadecimal digits of the SHA-256 of `sapoche-member:<clientId>`, and that is the id everybody sees (in `members`, `ownerId`, `addedBy`, `by`, and `you` in the device's own `state`). Knowing someone's public id therefore does not let a device join as them or as the owner. Rooms saved before public ids carry their old owner and `addedBy` over (hashing an old id gives the new one). `create:true` is a code the device just made up, `create:false` is a code it was given: if the room does not exist the server answers with the error `room_not_found` and closes with 4004 (a mistyped code does not open an empty room). A missing `create` is an old app, which is allowed to open the room as before |
| `bye` | | Leave on purpose (as opposed to losing the connection). When the owner sends `bye` the longest-present member becomes the owner; a room with nobody left has no owner |
| `kick` | `id` | Owner only: disconnect that member (closes 4001, with the error `removed`); they can join again |
| `room.name` | `name` | Rename the room, at most 32 characters, empty removes the name |
| `room.settings` | `guestControl` | Owner only: `all` (everybody steers, the default) or `add` (guests can only add songs) |
| `ping` | `c0`, `rtt?` | Clock measurement. `rtt` is the best round trip the device has measured so far, in ms; the server schedules starts from the slowest device that follows the room (section 5). Older apps leave it out |
| `avatar.set` | `data` | The device's own picture: base64 of a small JPEG or PNG (about 256 px), at most 24,000 characters; `null` takes it away. Anything else is ignored. Only servers of protocol 8 or newer know it, and an older one answers with `unknown_type`, so a client sends it only after a `state` that says `protocol` 8 or more |
| `avatar.get` | `id` | Asks for the picture of the member `id`; answered with `avatar` to this socket only |
| `queue.add` | `videoId`, metadata, `next?` | Add a song; `next: true` inserts it right after the current one (if the room is `idle` the new song is only appended and played) |
| `queue.addMany` | `tracks[]`, `next?` | Add several songs at once (a playlist), at most 100 per message, songs with a bad `videoId` are dropped; the same `next` rule as `queue.add`. One message and one `state` broadcast, so it does not run into the limit of 20 messages per second |
| `queue.remove` | `id` | Remove a song |
| `queue.swap` | `id`, `track` (`videoId`, `title`, `artist`, `thumb?`, `durMs`) | Replace the entry `id` with another release of the same song (video ↔ audio), keeping its place, its `id` and who added it. If it is the song being played (running, paused or preparing): broadcast a new `prepare` to every device, seek to exactly the current position (clipped to the length of the new release), then `start` once everybody is ready; a paused room plays on after the swap. A `videoId` equal to an existing one or an unknown `id` is ignored; a bad `videoId` gives `bad_video`. Restricted like `queue.move` when the owner lets guests only add songs. Protocol 7 |
| `queue.clear` | | Clear the whole queue, the room goes `idle` |
| `queue.shuffle` | | Shuffle the **upcoming** songs, the current one keeps its place. When the room is `idle` (the queue has run out) it shuffles everything and plays from the first song. With fewer than 2 songs it does nothing |
| `shuffle` | `on` | Turn the room's shuffle on or off (section 5g). Restricted like `repeat`. Anything but `true` or `false` is ignored. Protocol 11: a client sends it only after a `state` that carries `shuffle`, and otherwise falls back to `queue.shuffle` |
| `jump` | `id` | Play this song from the start now (through the barrier) |
| `queue.move` | `id`, `toIndex` | Change the position |
| `play` / `pause` | | Control. `play` when the room is `idle` at the last song (the queue has run out) plays again **from the first song**, not only the last one. `pause` while the room is `preparing` (the song is still loading) holds it there: the phase becomes `paused`, the barrier is dropped, and a later `play` starts it |
| `seek` | `positionMs` | Seek. While the room is `preparing` the barrier goes on: the new position is kept, the coming `start` carries it, and a device that joins meanwhile is told to prepare there |
| `next` / `prev` | `from?` | Change song; `next` at the last song with `repeat=all` goes back to the first. `from` is the id of the queue item the button was pressed on: if the room has already left it (somebody else skipped first) the press is ignored, so two people skipping at the same moment move the room one song, not two. Older apps leave it out, and their presses always count |
| `autoplay` | `on` | Turn the room's autoplay on or off (section 5e). Restricted like `repeat`: once the owner lets guests only add songs, only the owner may. Anything but `true` or `false` is ignored. Only servers of protocol 9 or newer know it, and an older one answers with `unknown_type`, so a client sends it only after a `state` that carries `autoplay` |
| `repeat` | `mode` | `off`: stop after the last song. `all`: when the queue ends, play it again from the start. `one`: when the current song ends, play it again (the `next` button still goes to the next song). Unknown values are ignored |
| `solo` | `on` | Start (`true`) or stop (`false`) listening alone: the room's commands no longer steer this device and the room does not wait for it at the barrier. The server forgets this flag when the socket drops, so the client sends it again after every reconnect |
| `resync` | | Ask the server to send `state` again (and `prepare` if the room is preparing) to this socket only; used when coming back to the room after listening alone |
| `ready` | `epoch` | The device has resolved the stream and buffered enough, ready to play |
| `chat` | `text`, `cid?` | A chat message to the room (section 5f). The text is trimmed and cut to 500 characters; one with no text is ignored. `cid` is the device's own id for the message (at most 40 characters), sent back with it so the device knows it arrived. Allowed to every member, whatever `guestControl` says. Protocol 10: a client sends it only after a `state` that says `protocol` 10 or more |
| `react` | `e`, `n?` | A reaction to the room: `e` is the name of one of the reactions in section 5f or one emoji itself, and `n` (1 to 10, 1 when absent) how many taps it stands for. Anything else is ignored. Not kept. Protocol 10 |
| `report` | `epoch`, `posMs`, `bufferMs` | Periodic position report (diagnostics only, every 10 seconds) |
| `resolveFailed` | `epoch`, `reason` | The device could not get the stream. It counts as answered, so it does not hold the others back; if **every** device in the room reports a failure the server sends an `error` with code `unplayable` and moves on to the next song (or `idle` if there are none) instead of running a silent clock |
| `ended` | `epoch` | The song ended with no preloaded song after it (the last song, or the preload failed) |
| `advanced` | `epoch`, `itemId`, `startedAt` | The device moved to the preloaded next song by itself; `startedAt` is the server time at which it heard position 0 of the new song |

## 4. Messages server → client

| `t` | Fields | Meaning |
|---|---|---|
| `state` | the whole state, `protocol` | Sent on joining and on big changes; `protocol` is the server's protocol version (currently 11) |
| `prepare` | `epoch`, song, `seekToMs`, `by?` | Prepare the song: resolve, buffer, then send `ready`. `by` is the `clientId` of whoever just changed the song; absent when the room moves on by itself |
| `start` | `epoch`, `startAt` (server time), `by?` | Start playing at this moment |
| `pause` | `epoch`, `positionMs`, `by?` | Stop at the position |
| `advance` | `epoch`, `index`, `startedAt` | The whole room moves to the next song without the barrier, position 0 heard at `startedAt` |
| `pong` | `c0`, `s1` | Answer to a ping |
| `autoplay.fill` | `epoch`, `videoId`, `title` | Sent to one device only, when autoplay is on and the queue has run out (section 5e): find songs like `videoId` and answer with `queue.addMany` |
| `avatar` | `id`, `av?`, `data?` | The picture of `id` and its fingerprint; both absent when that member has none |
| `chat` | `msg` (`id`, `by`, `name`, `text`, `at`, `cid?`) | A new chat message, to everybody including its sender (section 5f) |
| `chat.history` | `msgs[]` | The room's last chat messages (at most 100, oldest first), to the device that just joined, right after its `state` |
| `react` | `by`, `e`, `n` | Somebody else reacted; sent to everybody but the device that reacted |
| `members` | `members[]` | The member list, sent when someone joins, leaves, renames, changes solo mode, the owner changes, or someone switches between present and `away` |
| `error` | `code`, `message` | Codes today: `not_joined`, `bad_message`, `bad_json`, `rate_limited`, `unknown_type`, `bad_video`, `queue_full`, `unplayable`, `room_not_found` (with close 4004), `room_full` (with close 1008), `forbidden` (a command only the owner may give), `removed` (with close 4001) |

## 5. Changing song (the barrier)

1. A device sends `next` (or the current song ends).
2. The server increases `epoch`, sets `phase=preparing` and sends `prepare` to every device.
3. Every device resolves the URL, buffers about 3 seconds and sends `ready`.
4. When every device is `ready` (or after 8 seconds, skipping the slow ones) the server sets `startedAt = serverNow + lead` and `phase=playing`, and sends `start`. The lead is 1500 ms at most: when every device following the room (present, not alone) has said its round trip in its pings, it is the slowest round trip plus 400 ms, and never less than 600 ms. The same lead applies to every `start`, so play and seek answer sooner on a good network.
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

**Owner.** Whoever opens the room (`create:true`), or the first to join when the room has no owner, is the owner. `guestControl` defaults to `all`: everybody has equal rights, as before. When the owner switches to `add`, guests can only add songs (`queue.add`, `queue.addMany`) and listen alone; `play`, `pause`, `seek`, `next`, `prev`, `jump`, `queue.remove`, `queue.swap`, `queue.move`, `queue.clear`, `queue.shuffle`, `repeat` and `room.name` get `forbidden`. The limit only holds while the owner is present (socket open and not `away`); if the owner loses the connection everybody can steer, and when the owner is back the limit is back, with no handover timer. `kick` and `room.settings` are always owner-only. A room with nobody left loses its owner and `guestControl` goes back to `all`; the first to join afterwards becomes the new owner. Nobody left also stops the music where it was: a room that was playing, or still preparing a song, is `paused` for whoever comes back, so it never starts by itself.

**Lifecycle.** A code is only a name: a room is born when someone joins with `create` not equal to `false`, and does not exist before that. An empty room is kept for 7 days if there are songs left in its queue, for 1 hour if there are none, and then deleted entirely (`deleteAll`). The server has only one Durable Object alarm but keeps the due time of each job (`barrier`, `end`, `gc`, `sweep`) and sets the alarm at the nearest one. `sweep` runs every 5 minutes while the room has people: it closes sockets that have been silent for more than 150 seconds (even when nobody sends anything), so a room of dead devices still becomes empty and is cleaned up. A socket that has not joined (or was refused) creates no data. The server also understands the state stored in the old form (a single alarm).

## 5d. Pictures

A member's picture is not part of the member list: that list is sent whenever somebody is ready, away or solo, and a picture in it would be sent many times a song. Instead the list carries `av`, a fingerprint of 8 hexadecimal digits (the start of the SHA-256 of the picture's text). A client keeps the fingerprint it last fetched for each member and sends `avatar.get` only for a member whose `av` is new or changed, and drops what it holds for a member who has no `av` any more or who is gone.

The server keeps the pictures in storage, one per client id (a socket attachment holds only 2 KiB), and drops those of members who are no longer here. A device sends `avatar.set` once per connection, right after the first `state`; a device that comes back within the lifetime of the room keeps the picture it had, so it does not disappear from the others' screens for the moment of a reconnect. Setting the same picture again changes nothing for the others.

## 5e. Autoplay

When the queue runs out, a personal queue carries on with songs like the last one, and so can a room. The server cannot find the songs itself (YouTube blocks it), so it asks one device. `autoplay` in the state is the room's own setting, on in a new room, and any member may change it with `autoplay` as they may change `repeat`.

The server asks when the room goes `idle` because the last item ended or because somebody pressed next at the last item, `autoplay` is on and a device is here. It does not ask after an item that nobody could load (a run of broken songs would never end), when an item is removed or the queue is cleared, or when `repeat` keeps the room going. It sends `autoplay.fill` to a single device: one that follows the room before one listening on its own, the owner's before the others', then whoever has been here longest. A device that is `away` is not asked. The device finds songs like `videoId`, leaves out what is in the queue, and sends them with `queue.addMany`; an idle room that gets songs plays the first of them. A device drops the answer when the room's `epoch` is no longer the one in the request, since somebody has already started something else. If the device finds nothing (no network, no result) the room simply stays idle, as it did before.

## 5f. Chat and reactions

Members can write to each other and react while they listen. A chat message gets a number from the room (`id`, one more than the last), the server time (`at`), the sender's public id (`by`) and the sender's name as it was then (`name`, so a message keeps its author's name after they leave). The room keeps its last 100 messages in storage, apart from its state, and sends them as `chat.history` to every device right after the `state` it gets on joining or reconnecting; a device replaces what it held with them. The messages go when the room goes (section 5c). Each message costs one storage write; nothing else does.

A reaction is one of these, by name: `heart`, `love`, `kiss`, `hug`, `blush`, `cool`, `wink`, `pleading`, `laugh`, `rofl`, `grin`, `wow`, `mindblown`, `think`, `eyes`, `sad`, `cry`, `skull`, `sleepy`, `fire`, `clap`, `raise`, `party`, `hundred`, `sparkles`, `rocket`, `muscle`, `thumbsup`, `thumbsdown`, `ok`, `pray`, `music`, `dance`, `headphones`, `mic`, `guitar`, `drum`, `speaker`, `replay` (`REACTIONS` in `server/src/protocol.ts`). The app keeps six of them in reach in the chat and all the emoji a tap further. Any emoji of a keyboard can be sent as well, as itself: one pictograph, flag or keycap with its skin tone, variation selector and joiners, at most 32 UTF-16 units (the server tests what an emoji is made of, not a list, so newer ones pass too). Anything that is neither a name nor an emoji is ignored. An app shows the names it knows and any emoji; an app from before emoji could be sent shows only the names, so the app still sends the names for the ones that have them. A server from before this does not pass an emoji on, and drops it without an error. A reaction is passed on to the others at once and kept nowhere, so a device that is not listening simply misses it. The device that reacts shows its own reaction itself. A device gathers quick taps into one message with a count `n` (at most 10), so reacting never runs into the limit of 20 messages a second.

## 5g. Shuffle

`queue.shuffle` mixes the songs to come once. `shuffle` is the mode Apple Music has: **on**, the server remembers the order the queue had (apart from the state, never sent) and mixes the songs still to come, the current one keeping its place; songs added afterwards at the end are put at a random place among those to come, while one added with `next` stays next. **Off**, the songs still to come go back to the remembered order, and the ones added while it was on follow them, in the order they have. `shuffle` stays as it is when the queue is cleared or runs out; turning it on while the room is `idle` only sets the mode. `queue.shuffle` still works, changes no mode and is what a client uses with a server older than protocol 11.

## 6. Correcting drift while playing

Every 500 ms the client computes `drift = playerPosition - expectedPosition`:

| `|drift|` | Action |
|---|---|
| < 40 ms | Keep speed 1.0 |
| 40 ms to 400 ms | Set the speed to 0.97 or 1.03 until it gets close to 0 |
| > 400 ms | `seekTo(expectedPosition)`; if seeks keep failing, report an error |

The thresholds are starting values, to be tuned after measuring on real devices.

Measurements on a real phone show that the position ExoPlayer reports has a sawtooth noise of about 200 ms with a period of 3 to 4 seconds, so decisions are not based on single samples but on the **average over a window of 8 samples (4 seconds)**, after subtracting what was corrected by changing speed. The window is cleared after every seek and every time the player stops or buffers.

**Start latency.** Every device is heard about 150 to 350 ms later than asked after `play()` or a seek (audio output latency). The device learns it: after every normal start, the drift left in the first full window is added to `startBias` (factor 0.8, limited to ±800 ms, kept in the device's storage), and the next time it seeks ahead by exactly that amount. A start that is more than 200 ms off after the first 3 readings (a device that has never learned its delay, or a new output) is learned from at once and fixed with one seek, instead of 10 seconds or more at 0.97/1.03. There is also a `trim` that the person sets by hand for devices with an unusual latency (a Bluetooth speaker).

## 7. Recovery

- WebSocket dropped: the client reconnects by itself (backoff 1 s, 2 s, 4 s, at most 15 s), joins again with `join` and the same `clientId`, receives a new `state` and syncs again. When Android reports that the network is back or changed, the wait is skipped and it reconnects at once.
- Rejoining a room that is playing the very song already loaded does not reload it: it only re-aligns to the room's time origin (and presses play if the device is paused).
- A repeated `prepare` with the same `epoch` for a device that has finished loading: it only sends `ready` again.
- Losing the network mid-song: the player retries network errors for up to about 8 minutes and carries on from its buffer; only a URL that is refused (401, 403, 404, 410) reports an error at once so that it is loaded again with a fresh URL. If loading again fails (no network yet) it retries every 5 seconds.
- The process is killed by the system: the app stores the room code, the last time it was alive (written every minute while in a room) and the solo mode. If the service restarts within 10 minutes it rejoins the room (`join` with `create:false`), and if it was listening alone it rejoins in solo mode, paused, without playing by itself. After 10 minutes, or when the app is opened normally, it starts outside a room with the personal queue.
- A long pause: in a room, not playing and with the screen not shown for more than 20 minutes, the client closes the WebSocket (a ping every 30 seconds keeps the radio awake all day); it reconnects when the screen is shown or when a command arrives from the notification (the command is held until the connection is up). The server sees a member leaving, and the room lets everybody steer if that member was the owner.
- A connection that died without closing: the client uses exactly one ping (30 seconds) and treats the connection as dead if there is no `pong` for 45 seconds, then reconnects; there is no OkHttp protocol-level ping any more.
- The device stops by itself (a call, another app taking the audio) while the room is playing: the play button only resumes on that device, the room is not restarted; a large drift is handled with one seek.
- Pause from outside the app (a headset button, AirPods taken out, a watch, the notification or lock screen) is the same: it pauses only this device and sends nothing to the room, because such a command cannot tell a person's choice from an ear coming out. The buttons inside the app are the room's. The app shows play on a device in that state (with "Paused here · room plays on"), and such a device is **held**: what the room does meanwhile (the next song, a start) loads there but does not play, so it never takes the sound back from the other app by itself. Its person presses play, and the device goes to where the room is now and plays from there. The same holds when another app takes the audio for good or the headphones go away (a call that ends and says the sound may go on resumes by itself). A device that goes solo, or follows the room again, is no longer held.
- The Durable Object sleeps (Hibernation): the state is in storage and is not lost when it wakes up.
- Messages with an old `epoch` are ignored.

## 8. Open points (to verify by measuring)

- Whether the start lead (600 to 1500 ms, from the devices' round trips) is enough for slow devices; a device that gets the start late skips ahead as a late joiner does.
- Whether the drift thresholds and the speed correction make the sound distort.
- How to handle two people pressing controls at the same time. `next` and `prev` name the item they were pressed on (as Jellyfin SyncPlay does), so a second press for the same item does nothing; for `play`, `pause` and `seek` the message that reaches the server last wins, and every device is told the same.
