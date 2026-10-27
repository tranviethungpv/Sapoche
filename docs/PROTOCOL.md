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
  "theme": "ocean",
  "bg": "3fa9c01e",
  "ownerId": "u1",
  "guestControl": "all | add",
  "autoplay": true,
  "shuffle": false,
  "members": [{ "id": "u1", "name": "Ann", "ready": true, "solo": false, "away": false, "owner": true, "av": "3fa9c01e" }]
}
```

`name` and `ownerId` may be absent. `theme` is the look of the chat (section 5j): `default` when the room has none, and absent when the server is older than protocol 16. `bg` is the fingerprint of the picture behind the chat and is absent when there is none. See section 5c for the owner and the room name. Member ids, `ownerId`, `addedBy`, `by` and `you` are **public ids**, never the `clientId` a device joins with (section 3). `autoplay` says whether the room carries on by itself when its queue runs out (section 5e); it is absent when the server is older than protocol 9. `shuffle` says whether shuffle is on (section 5g); it is absent when the server is older than protocol 11. `av` is the fingerprint of the member's picture and is absent when they have none; see section 5d. A queue item has `"auto": true` when autoplay put it there and not a member (section 5e); the field is absent otherwise, and from servers older than protocol 12.

- `phase=playing`: the current position is `serverNow - startedAt`.
- `phase=paused`: the position is `positionMs`.
- `epoch` increases whenever a change makes the old state obsolete (song change, seek, play/pause). Clients ignore messages with an old `epoch`.

## 2. Measuring the clock offset (simple NTP)

The client sends `{t:"ping", c0}` (c0 = the client's clock). The server answers `{t:"pong", c0, s1}` (s1 = the server's clock). When the client receives it at c2:
- `rtt = c2 - c0`
- `offset = s1 - (c0 + rtt/2)` (server time ≈ local time + offset)

It measures 8 times when joining and keeps the sample with the smallest `rtt`. It measures again every 30 seconds while the screen is on, and every few minutes in the background.

## 2b. Authentication

`POST /rooms`, `GET /room/<CODE>/info` and `WS /room/<CODE>` need the shared key `ROOM_KEY` (header `X-Sapoche-Key`, or the parameter `?key=` where no header can be set). A wrong or missing key gets HTTP 401 before the WebSocket upgrade; the client treats that as a final error and does not retry. Three routes are always open: `GET /health` returns `{"ok":true,"protocol":16}`; `GET /join/<CODE>` is the page an invitation link opens (it tries to open the app with `intent://`, and otherwise shows the code); `GET /.well-known/assetlinks.json` lets Android verify the app's https links. These three do not touch any room, so they need no key. Operational details are in [../server/README.md](../server/README.md).

`GET /room/<CODE>/info` is read-only and creates nothing: `{"exists":true,"name":"Family","members":2,"playing":true,"title":"..."}`; `exists:false` when the room never existed or has expired. The app uses it for the list of recent rooms.

## 3. Messages client → server

| `t` | Fields | Meaning |
|---|---|---|
| `join` | `name`, `clientId`, `create?`, `caps?` | Join a room; the server answers with `state`. `clientId` is the device's own secret: the room knows the device by its public id, the first 16 hexadecimal digits of the SHA-256 of `sapoche-member:<clientId>`, and that is the id everybody sees (in `members`, `ownerId`, `addedBy`, `by`, and `you` in the device's own `state`). Knowing someone's public id therefore does not let a device join as them or as the owner. Rooms saved before public ids carry their old owner and `addedBy` over (hashing an old id gives the new one). `create:true` is a code the device just made up, `create:false` is a code it was given: if the room does not exist the server answers with the error `room_not_found` and closes with 4004 (a mistyped code does not open an empty room). A missing `create` is an old app, which is allowed to open the room as before. `caps` (protocol 15) lists what the app can do; `"e2ee"` says it reads and writes sealed chat, and a room whose chat is end-to-end encrypted (section 5i) refuses a device without it: error `needs_update` and close 4005 |
| `bye` | | Leave on purpose (as opposed to losing the connection). When the owner sends `bye` the longest-present member becomes the owner; a room with nobody left has no owner |
| `kick` | `id` | Owner only: disconnect that member (closes 4001, with the error `removed`); they can join again |
| `room.name` | `name` | Rename the room, at most 32 characters, empty removes the name |
| `room.theme` | `theme`, `bg?` | The look of the room's chat, for everybody, with the picture behind it (section 5j). Restricted like `room.name`. Protocol 16 |
| `room.settings` | `guestControl` | Owner only: `all` (everybody steers, the default) or `add` (guests can only add songs) |
| `ping` | `c0`, `rtt?` | Clock measurement. `rtt` is the best round trip the device has measured so far, in ms; the server schedules starts from the slowest device that follows the room (section 5). Older apps leave it out |
| `avatar.set` | `data` | The device's own picture: base64 of a small JPEG or PNG (about 256 px), at most 24,000 characters; `null` takes it away. Anything else is ignored. Only servers of protocol 8 or newer know it, and an older one answers with `unknown_type`, so a client sends it only after a `state` that says `protocol` 8 or more |
| `avatar.get` | `id` | Asks for the picture of the member `id`; answered with `avatar` to this socket only |
| `queue.add` | `videoId`, metadata, `next?` | Add a song; `next: true` inserts it right after the current one (if the room is `idle` the new song is only appended and played) |
| `queue.addMany` | `tracks[]`, `next?`, `auto?` | Add several songs at once (a playlist), at most 100 per message, songs with a bad `videoId` are dropped; the same `next` rule as `queue.add`. One message and one `state` broadcast, so it does not run into the limit of 20 messages per second. `auto: true` marks the songs as what autoplay found for a room that ran out (section 5e); the room takes them only while it is `idle` and with autoplay on, and otherwise ignores the message. Protocol 12 |
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
| `room.encrypt` | | Owner only (`forbidden` for anyone else): turns on end-to-end encryption of the room's chat, for good, and deletes the chat so far (section 5i). Protocol 15 |
| `chat` | `text`, `cid?`, `reply?` (`ct`, `pv?` instead of `text` in a sealed room) | A chat message to the room (section 5f); in a room with end-to-end encryption `ct` and `pv` take the place of `text` (section 5i). The text is trimmed and cut to 500 characters; one with no text is ignored. `cid` is the device's own id for the message (at most 40 characters), sent back with it so the device knows it arrived. `reply` is the `id` of the message this one answers; the room attaches what it says (`re`), and sends the text alone when it no longer has that message. Allowed to every member, whatever `guestControl` says. Protocol 10: a client sends it only after a `state` that says `protocol` 10 or more (`reply` is ignored by servers older than 12) |
| `chat.react` | `id`, `e` | This member's reaction to the chat message `id`: `e` is the name of one of the reactions in section 5f or one emoji, and `null` takes it away. A member has one reaction to a message, and a new one replaces the old. An unknown `id` or a bad `e` is ignored. Protocol 12 |
| `chat.before` | `id`, `n?` | Asks for up to `n` (50 when absent, at most 100) of the chat messages older than message `id`, newest of them last; answered with `chat.page` to this socket only (section 5f). Protocol 14 |
| `chat.receipt` | `delivered?`, `read?` | How far this device has got in the chat, by message `id` (section 5f): `delivered` the last message that reached the device, `read` the last one it showed to a person. Numbers only go forward and are cut to the last message the room has. Protocol 12 |
| `push.set` | `sub`, `room`, `until?`, `preview?`, `lang?` | Asks to be told of the chat while this device is away (section 5h): `sub` is the browser's push subscription (`endpoint`, `keys.p256dh`, `keys.auth`), `room` the code of this room, for the notice to open it. `until` keeps it quiet until that server time in ms; `preview: false` leaves the words of the messages out of the notices; `lang` is the language they are written in. Sent again after every join, which also keeps the device fresh. An endpoint that is not a push service is refused with `bad_message`, a server without keys answers `push_unavailable`. Protocol 13 |
| `push.clear` | | Stops being told of the chat. `bye` and `kick` do this too. Protocol 13 |
| `react` | `e`, `n?` | A reaction to the room: `e` is the name of one of the reactions in section 5f or one emoji itself, and `n` (1 to 10, 1 when absent) how many taps it stands for. Anything else is ignored. Not kept. Protocol 10 |
| `report` | `epoch`, `posMs`, `bufferMs` | Periodic position report (diagnostics only, every 10 seconds) |
| `resolveFailed` | `epoch`, `reason` | The device could not get the stream. It counts as answered, so it does not hold the others back; if **every** device in the room reports a failure the server sends an `error` with code `unplayable` and moves on to the next song (or `idle` if there are none) instead of running a silent clock |
| `ended` | `epoch` | The song ended with no preloaded song after it (the last song, or the preload failed) |
| `advanced` | `epoch`, `itemId`, `startedAt` | The device moved to the preloaded next song by itself; `startedAt` is the server time at which it heard position 0 of the new song |

## 4. Messages server → client

| `t` | Fields | Meaning |
|---|---|---|
| `state` | the whole state, `protocol` | Sent on joining and on big changes; `protocol` is the server's protocol version (currently 15) |
| `prepare` | `epoch`, song, `seekToMs`, `by?` | Prepare the song: resolve, buffer, then send `ready`. `by` is the `clientId` of whoever just changed the song; absent when the room moves on by itself |
| `start` | `epoch`, `startAt` (server time), `by?` | Start playing at this moment |
| `pause` | `epoch`, `positionMs`, `by?` | Stop at the position |
| `advance` | `epoch`, `index`, `startedAt` | The whole room moves to the next song without the barrier, position 0 heard at `startedAt` |
| `pong` | `c0`, `s1` | Answer to a ping |
| `autoplay.fill` | `epoch`, `videoId`, `title` | Sent to one device only, when autoplay is on and the queue has run out (section 5e): find songs like `videoId` and answer with `queue.addMany` |
| `avatar` | `id`, `av?`, `data?` | The picture of `id` and its fingerprint; both absent when that member has none |
| `chat` | `msg` (`id`, `by`, `name`, `text`, `at`, `cid?`) | A new chat message, to everybody including its sender (section 5f) |
| `chat.history` | `msgs[]`, `receipts?`, `more?` | The room's last chat messages (at most 100, oldest first), to the device that just joined, right after its `state`. `receipts` (protocol 12) says how far each member has got, as in `chat.receipts`. `more` (protocol 14) says the room keeps messages from before these, to be asked for with `chat.before`; absent from older servers, which keep nothing else |
| `chat.page` | `before`, `msgs[]`, `more` | The answer to `chat.before`: the messages older than `before`, oldest first, and whether the room keeps ones from before them. Protocol 14 |
| `chat.update` | `msg` | A chat message changed, as somebody reacted to it: its new version, to everybody. Protocol 12 |
| `chat.receipts` | `receipts` | What each member has got of the chat, to everybody, whenever it changes: `{"<member id>": {"d": 7, "r": 5}}`, `d` the last message that reached their device and `r` the last one they looked at. Protocol 12 |
| `react` | `by`, `e`, `n` | Somebody else reacted; sent to everybody but the device that reacted |
| `members` | `members[]` | The member list, sent when someone joins, leaves, renames, changes solo mode, the owner changes, or someone switches between present and `away` |
| `error` | `code`, `message` | Codes today: `not_joined`, `bad_message`, `bad_json`, `rate_limited`, `unknown_type`, `bad_video`, `queue_full`, `unplayable`, `room_not_found` (with close 4004), `room_full` (with close 1008), `forbidden` (a command only the owner may give), `removed` (with close 4001), `needs_update` (with close 4005: the room is sealed and the app cannot read it) |

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

**Lifecycle.** A code is only a name: a room is born when someone joins with `create` not equal to `false`, and does not exist before that. An empty room is kept for 7 days if there are songs left in its queue, for 1 hour if there are none, and then its songs and settings are dropped; the room itself is deleted entirely (`deleteAll`) unless it has chat messages left, in which case it keeps its name and its chat until the last message is 180 days old (section 5f). Protocol 14. The server has only one Durable Object alarm but keeps the due time of each job (`barrier`, `end`, `gc`, `sweep`) and sets the alarm at the nearest one. `sweep` runs every 5 minutes while the room has people: it closes sockets that have been silent for more than 150 seconds (even when nobody sends anything), so a room of dead devices still becomes empty and is cleaned up. A socket that has not joined (or was refused) creates no data. The server also understands the state stored in the old form (a single alarm).

## 5d. Pictures

A member's picture is not part of the member list: that list is sent whenever somebody is ready, away or solo, and a picture in it would be sent many times a song. Instead the list carries `av`, a fingerprint of 8 hexadecimal digits (the start of the SHA-256 of the picture's text). A client keeps the fingerprint it last fetched for each member and sends `avatar.get` only for a member whose `av` is new or changed, and drops what it holds for a member who has no `av` any more or who is gone.

The server keeps the pictures in storage, one per client id (a socket attachment holds only 2 KiB), and drops those of members who are no longer here. A device sends `avatar.set` once per connection, right after the first `state`; a device that comes back within the lifetime of the room keeps the picture it had, so it does not disappear from the others' screens for the moment of a reconnect. Setting the same picture again changes nothing for the others.

## 5e. Autoplay

When the queue runs out, a personal queue carries on with songs like the last one, and so can a room. The server cannot find the songs itself (YouTube blocks it), so it asks one device. `autoplay` in the state is the room's own setting, on in a new room, and any member may change it with `autoplay` as they may change `repeat`.

The server asks when the room goes `idle` because the last item ended or because somebody pressed next at the last item, `autoplay` is on and a device is here. It does not ask after an item that nobody could load (a run of broken songs would never end), when an item is removed or the queue is cleared, or when `repeat` keeps the room going. It sends `autoplay.fill` to a single device: one that follows the room before one listening on its own, the owner's before the others', then whoever has been here longest. A device that is `away` is not asked. The device finds songs like `videoId`, leaves out what is in the queue, and sends them with `queue.addMany`; an idle room that gets songs plays the first of them. A device drops the answer when the room's `epoch` is no longer the one in the request, since somebody has already started something else. If the device finds nothing (no network, no result) the room simply stays idle, as it did before.

**Autoplay songs stay apart from the members' queue (protocol 12).** A device answers with `queue.addMany` and `auto: true`, and the room marks those items `auto: true`. The room takes such a message only while it is `idle` and autoplay is on; at any other time it is the answer to a question the room has moved past. The marked items are not part of the list the members made: a song a member adds goes before them (a plain add goes after the members' last song, `next` right after the song playing), shuffle and the shuffle mode mix only the members' songs and leave them at the end, and a member who moves one into the list makes it theirs (the mark goes). A member who adds a song that autoplay had lined up gets that song as their own, and the lined-up copy is removed. When the room has played everything, the marked items are taken out of the queue (the index then points at the last of the members' songs, so that `play` starts the list again from the top), and autoplay asks for more from the last song that played. Turning autoplay off takes away the marked items still to come but not the one playing. Older apps know nothing of the mark and show these songs as part of the queue; older servers ignore `auto` and add the songs as any others.

## 5f. Chat and reactions

Members can write to each other and react while they listen. A chat message gets a number from the room (`id`, one more than the last), the server time (`at`), the sender's public id (`by`) and the sender's name as it was then (`name`, so a message keeps its author's name after they leave). The room keeps its messages in storage, apart from its state, and sends the last 100 as `chat.history` to every device right after the `state` it gets on joining or reconnecting; a device replaces what it held with them.

**Further back (protocol 14).** The room keeps a message for 180 days, and no more than 5000 messages (whichever limit is reached first; the latest message always stays, so the numbers go on). A device that wants to read further back than the last 100 sends `chat.before` with the number of the oldest message it has, and gets `chat.page`; the `more` of `chat.history` and `chat.page` says whether there is anything left to ask for. An answer to a message, or a reaction to one, works for any message the room still keeps. The chat does not go when the room's songs and settings do (section 5c): a room whose members have all gone keeps its name and its chat, and stays open to join, until its last message is 180 days old. Each message costs one storage write; nothing else does.

**Answers (protocol 12).** A message sent with `reply` carries `re`, what it answers as it was when the answer was written: `{id, by, name, text}` with the text cut to 100 characters (with a `…` when it was longer). It lives with the answer, so it stays when the original is no longer among the last 100. An answer to an answer quotes the text of the answer, not its quote.

**Reactions to a message (protocol 12).** `chat.react` sets this member's reaction to a message, `null` takes it away; the message then carries `rx`, a map from the public id of each member who reacted to the reaction (a name from the list below or an emoji), absent when nobody has. The room sends the changed message to everybody as `chat.update`; nothing is sent when the reaction is the one the member already had. These reactions are kept with the message, unlike the ones that fly (`react`).

**Receipts (protocol 12).** A device says with `chat.receipt` how far it has got: `delivered`, the last message that reached the device whether or not anyone looked (the app says so on its own as messages come in, even with its screen off), and `read`, the last message it showed to a person with the chat open. The room keeps one pair `{d, r}` per member, apart from the messages, where `read` implies `delivered`, and a member who writes a message has read up to it. It sends them as `chat.receipts` to everybody when one changes and with `chat.history` to whoever joins. An app shows a message of its own as sent (the room has it), delivered (another member's `d` reaches it) or seen (another member's `r` does), and marks where each member stopped reading. Only members who are here or wrote one of the last 100 messages keep a receipt. Each change costs one storage write.

A reaction is one of these, by name: `heart`, `love`, `kiss`, `hug`, `blush`, `cool`, `wink`, `pleading`, `laugh`, `rofl`, `grin`, `wow`, `mindblown`, `think`, `eyes`, `sad`, `cry`, `skull`, `sleepy`, `fire`, `clap`, `raise`, `party`, `hundred`, `sparkles`, `rocket`, `muscle`, `thumbsup`, `thumbsdown`, `ok`, `pray`, `music`, `dance`, `headphones`, `mic`, `guitar`, `drum`, `speaker`, `replay` (`REACTIONS` in `server/src/protocol.ts`). The app keeps six of them in reach in the chat and all the emoji a tap further. Any emoji of a keyboard can be sent as well, as itself: one pictograph, flag or keycap with its skin tone, variation selector and joiners, at most 32 UTF-16 units (the server tests what an emoji is made of, not a list, so newer ones pass too). Anything that is neither a name nor an emoji is ignored. An app shows the names it knows and any emoji; an app from before emoji could be sent shows only the names, so the app still sends the names for the ones that have them. A server from before this does not pass an emoji on, and drops it without an error. A reaction is passed on to the others at once and kept nowhere, so a device that is not listening simply misses it. The device that reacts shows its own reaction itself. A device gathers quick taps into one message with a count `n` (at most 10), so reacting never runs into the limit of 20 messages a second.

## 5h. Notices of the chat to a device that is away (protocol 13)

A phone that has the app open is told of the chat by the connection it already has; this is for a **browser** whose page is in the background or closed. It is Web Push (RFC 8030): the device subscribes in the browser, gives the subscription with `push.set`, and the room sends a notice to the push service of that browser when something happens that the person should hear of. Nothing is sent to an app: the phone apps show their own notifications from the messages they hold, while they are connected.

- **What is told, and to whom.** A new message goes to every device that asked, except the one that wrote it; if it answers a message of the device (`re.by` is its id) it goes as an answer. A reaction given to a message (`chat.react` with an emoji, not taking one away) goes to the device that wrote the message, unless it is the one that reacted.
- **Who is "in the room".** A device that asked is told while it is connected, and for 12 hours after its connection closed (the time it was last seen). After that its subscription is let go, and it asks again at its next join. `bye`, `kick`, and a push service that answers 401, 403, 404 or 410 end it at once.
- **The notice.** The body of the push is JSON, encrypted for the browser (RFC 8291, `aes128gcm`) so that the push service cannot read it, with the server's VAPID signature (RFC 8292): `{"k": "chat" | "reply" | "react", "room", "rn"?, "name", "text"?, "pv"?, "by"?, "e"?, "l"?}`: the kind, the code and name of the room, who wrote or reacted, the text of the message (for a sealed room the sealed preview `pv` instead, with `by`, the public id of whoever wrote the message it is of, which it was sealed for: section 5i; cut to 120 characters; of the message reacted to for `react`; left out when the device asked for no preview), the reaction, and the language the device asked for. The server writes no sentence: the page does, from these words.
- **Keys.** The public half of the VAPID key is given by `GET /push/key` (`{"key": "…"}`, with the room key like the other routes; 404 when the server has no keys). A device subscribes with it as `applicationServerKey`.
- **Limits.** At most 24 devices ask in one room; `push.set` is refused for any endpoint outside `*.googleapis.com`, `*.push.services.mozilla.com`, `*.push.apple.com`, `*.notify.windows.com`, so that the server cannot be sent to an address a client chose. Asking costs a storage write, a notice none.

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

## 5i. End-to-end encryption of the chat (protocol 15)

The owner can turn it on for a room, for good (`room.encrypt`). From then on the state carries `enc: true`, `GET /room/<CODE>/info` says `"enc": true`, and the room keeps and passes on **sealed** messages, which it cannot read. The chat written in the clear so far is deleted (with what each member had got of it), and every device that did not say `"e2ee"` in `caps` when joining is sent `needs_update` and closed with 4005, as is one that tries later. Nothing about a room that is not sealed changes.

- **The secret.** 32 random bytes made on the owner's device, handed to the others in the invitation link after a `#` (`https://<server>/join/<CODE>#k=<base64url>`, or `sapoche://join/<CODE>?k=...`), never through the server: the page the link opens reads the fragment and passes it on to the app (`intent://...?k=`) or the web app (`/?join=<CODE>#k=`). The room has no key and no way to get one.
- **The key** of a message is HKDF-SHA256 of the secret, salt `sapoche-chat-v1`, info `<CODE>|<epoch>` (the code in capitals, the epoch a decimal number, 1 until keys can change), 32 bytes.
- **A sealed message** is `ct`, base64url without padding of: version (1), epoch (1), a random nonce (12 bytes), and AES-256-GCM of the words with its 16-byte tag. The associated data is `sapoche-chat-v1|<CODE>|<by>|<epoch>` (`by`: the public id of the sender), so the room can neither move a message to another room nor give it another sender. What is sealed is JSON `{"t": <text>, "q": {"id", "by", "name", "text"}?}` (`q` is the message answered, as a reply shows it; the room attaches no `re` to a sealed message), padded with spaces to a multiple of 64 bytes. `pv` is the first 120 characters of the text sealed apart (the same, with `|pv` added to the associated data), for a notice.
- **What the room does.** A `chat` with `ct` (base64url, at most 4096 characters) and `pv` (at most 600) is numbered, stamped and passed on as it is, with `text` empty. A `chat` with `text` in a sealed room, or a `ct` that is not base64url or too long, is ignored. `reply` stays plain: it is the number of the message answered, which a notice of an answer needs. Reactions (`rx`), receipts and paging (`chat.before`) work as before. A notice for a device away carries `pv` and `by` in place of `text`; the browser opens it with the secret it keeps.
- **What the room still sees:** who writes, when, how much (to within 64 bytes), which reactions, and the rest of the room (songs, members, name, pictures).
- **Limits.** No forward secrecy; the secret does not change when somebody is removed (a new room does that); the room cannot tell that a message was dropped or reordered except by a gap in the numbers.

Test vectors for the three implementations (Kotlin, Swift, Dart) are in `native/sync/src/test/resources/e2ee_vectors.json`.

## 5j. The look of the chat (protocol 16)

Every room has one look for its chat, which every member sees: `state.theme`, a short name the apps know, `default` for the colours of the app. A device changes it with `room.theme`; the room accepts a name that matches `^[a-z0-9-]{1,24}$` (anything else is ignored, not an error) and sends the state again, with `default` taking the theme away. The server does not know what the names mean, so a new look needs no new server. It is restricted like `room.name`: once the owner has restricted guests to adding songs (section 5c), a guest gets `forbidden`.

The names the apps know are a few presets (`ocean`, `sunset`, `forest`, `grape`, `honey`, `mono`), and `c-<rrggbb>-<rrggbb>`, two colours (hexadecimal) that a device took from a photo. An app that does not know a name shows the chat in the colours of the app. The theme is not part of the chat, so it works in a room whose chat is sealed (section 5i), and it stays with the room as long as the chat does (section 5c).

**The picture behind the chat.** `room.theme` may carry `bg`: base64 of a JPEG of at most 90 000 characters (the device cuts and compresses it to the shape of a phone standing up, about 540 px wide), where a string puts it behind the chat, `null` takes it away and leaving it out changes nothing; a `bg` that is not base64 or is too long makes the room ignore the whole message. `room.theme` is the one message that may be longer than 32 768 characters (up to 98 304). The state carries only `bg`, a fingerprint of 8 hexadecimal digits like the one of a member's picture (section 5d), and a client that sees a new one sends `avatar.get` for the id `room:bg` (no member's public id looks like it) and gets `avatar` with `av` and `data`, or without them when the picture went. Like the pictures of members it is not sealed in a room whose chat is (section 5i): the room, and so the server, can see it. The room keeps one picture, as long as it keeps the theme.
