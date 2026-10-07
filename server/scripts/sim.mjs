// End-to-end simulation of the room protocol against a running server (`npm run dev`).
// Usage: node scripts/sim.mjs [baseUrl]   (default http://127.0.0.1:8787)
// When the server has a ROOM_KEY, pass it in SAPOCHE_KEY (npm run sim:keyed does this against a local server).
import { createHash } from "node:crypto";

const BASE = process.argv[2] ?? "http://127.0.0.1:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const KEY = process.env.SAPOCHE_KEY ?? "";
const keyQuery = KEY ? `?key=${encodeURIComponent(KEY)}` : "";
const keyHeaders = KEY ? { "X-Sapoche-Key": KEY } : {};

let passed = 0;
let failed = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** The id the room shows for the device whose secret id is [clientId], as the server derives it. */
const pid = (clientId) => createHash("sha256").update(`sapoche-member:${clientId}`).digest("hex").slice(0, 16);

function check(name, condition, detail = "") {
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} ${detail}`);
  }
}

class Client {
  constructor(code, clientId, name) {
    this.clientId = clientId;
    this.name = name;
    this.inbox = [];
    this.waiters = [];
    this.ws = new WebSocket(`${WS_BASE}/room/${code}${keyQuery}`);
    this.opened = new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
    this.ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      msg._at = Date.now();
      this.inbox.push(msg);
      this.waiters = this.waiters.filter((w) => !w(msg));
    };
    /** The close code once the connection ends. */
    this.closed = new Promise((resolve) => {
      this.ws.onclose = (event) => resolve(event.code);
    });
  }

  /** [create] is what the device expects: true for a code it made up, false for one it was given; left out is an older app. */
  async join(create) {
    await this.opened;
    this.send({ t: "join", clientId: this.clientId, name: this.name, ...(create === undefined ? {} : { create }) });
    return this.waitFor((m) => m.t === "state");
  }

  send(msg) {
    this.ws.send(JSON.stringify(msg));
  }

  /** Resolves with the next matching message, looking at messages already received first. */
  waitFor(predicate, timeoutMs = 3000) {
    const existing = this.inbox.find(predicate);
    if (existing) {
      this.inbox.splice(this.inbox.indexOf(existing), 1);
      return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const waiter = (msg) => {
        if (!predicate(msg)) return false;
        clearTimeout(timer);
        this.inbox.splice(this.inbox.indexOf(msg), 1);
        resolve(msg);
        return true;
      };
      // A waiter that gave up must go too, or it would swallow a message meant for the next one
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(new Error(`${this.name}: timeout waiting for message`));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  /** True when no matching message shows up within [ms]. */
  async stays(predicate, ms) {
    try {
      await this.waitFor(predicate, ms);
      return false;
    } catch {
      return true;
    }
  }

  close() {
    this.ws.close();
  }
}

const all = (clients, fn) => Promise.all(clients.map(fn));
const VIDEO_A = "bNp9pn0ni3I";
const VIDEO_B = "UoXllQoqEBY";
const VIDEO_C = "cnHHCR7EW10";

async function main() {
  if (process.env.SIM_ONLY === "lifetime") {
    await lifetimeSection();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
  }
  if (process.env.SIM_ONLY === "conformance") {
    await conformanceSection();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
  }
  if (process.env.SIM_ONLY === "chat") {
    await chatSection();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
  }
  if (process.env.SIM_ONLY === "crossfire") {
    await crossfireSection();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
  }
  console.log("Health and room creation");
  const health = await fetch(`${BASE}/health`);
  const healthBody = await health.json();
  check("GET /health is ok and reports the protocol version", health.ok && healthBody.ok === true && healthBody.protocol >= 3, JSON.stringify(healthBody));
  if (KEY) await authSection();
  const created = await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json();
  check("POST /rooms returns a 6 character code", /^[A-Z2-9]{6}$/.test(created.code), JSON.stringify(created));
  const code = created.code;

  console.log("Joining and clock sync");
  const a = new Client(code, "dev-a", "Anna");
  const b = new Client(code, "dev-b", "Ben");
  const c = new Client(code, "dev-c", "Cara");
  const [sa] = await all([a, b, c], (x) => x.join());
  check("join returns state with idle phase", sa.state.phase === "idle" && sa.you === pid("dev-a"));

  const c0 = Date.now();
  a.send({ t: "ping", c0 });
  const pong = await a.waitFor((m) => m.t === "pong");
  const rtt = Date.now() - c0;
  check("pong echoes c0 and carries server time", pong.c0 === c0 && Math.abs(pong.s1 - Date.now()) < 1500, `rtt=${rtt}`);

  console.log("Errors");
  const rogue = new Client(code, "rogue", "Rogue");
  await rogue.opened;
  rogue.send({ t: "play" });
  const notJoined = await rogue.waitFor((m) => m.t === "error");
  check("commands before join are rejected", notJoined.code === "not_joined");
  rogue.ws.send("not json");
  const badJson = await rogue.waitFor((m) => m.t === "error");
  check("invalid JSON is rejected", badJson.code === "bad_json");
  rogue.close();
  a.send({ t: "queue.add", videoId: "short", title: "x", artist: "y", durMs: 1000 });
  const badVideo = await a.waitFor((m) => m.t === "error");
  check("invalid videoId is rejected", badVideo.code === "bad_video");

  console.log("Barrier: prepare, ready, start");
  a.send({ t: "queue.add", videoId: VIDEO_A, title: "Song A", artist: "Artist", durMs: 200000 });
  const prepares = await all([a, b, c], (x) => x.waitFor((m) => m.t === "prepare"));
  const epoch1 = prepares[0].epoch;
  check("all devices receive the same prepare", prepares.every((p) => p.epoch === epoch1 && p.item.videoId === VIDEO_A));

  // A stale epoch must not count
  a.send({ t: "ready", epoch: epoch1 - 1 });
  a.send({ t: "ready", epoch: epoch1 });
  b.send({ t: "ready", epoch: epoch1 });
  check("no start while one device is not ready", await c.stays((m) => m.t === "start", 600));
  c.send({ t: "ready", epoch: epoch1 });
  const starts = await all([a, b, c], (x) => x.waitFor((m) => m.t === "start"));
  const lead = starts[0].startAt - starts[0]._at;
  check("all devices get the identical start", starts.every((s) => s.startAt === starts[0].startAt && s.positionMs === 0 && s.epoch === epoch1));
  check("start is scheduled about 1.5s ahead", lead > 800 && lead < 1800, `lead=${lead}`);

  console.log("Pause, resume, seek");
  await sleep(2500); // let the scheduled start pass
  b.send({ t: "pause" });
  const pauses = await all([a, b, c], (x) => x.waitFor((m) => m.t === "pause"));
  check("pause reports the position reached", pauses[0].positionMs > 500 && pauses[0].positionMs < 1600, `pos=${pauses[0].positionMs}`);
  check("pause bumps the epoch", pauses[0].epoch > epoch1);

  c.send({ t: "play" });
  const resumes = await all([a, b, c], (x) => x.waitFor((m) => m.t === "start"));
  check("resume continues from the paused position", Math.abs(resumes[0].positionMs - pauses[0].positionMs) < 5);

  a.send({ t: "seek", positionMs: 60000 });
  const seeks = await all([a, b, c], (x) => x.waitFor((m) => m.t === "start"));
  check("seek while playing restarts at the new position for everyone", seeks.every((s) => s.positionMs === 60000 && s.startAt === seeks[0].startAt));

  console.log("Late joiner");
  await sleep(2000);
  const d = new Client(code, "dev-d", "Dan");
  const sd = await d.join();
  // The seek put position 60000 at server time seeks[0].startAt, so the joiner must derive exactly
  // that plus the server time elapsed since. Using only server timestamps keeps this independent of
  // network latency and local clock skew.
  const heard = sd.serverNow - sd.state.startedAt;
  const expected = 60000 + (sd.serverNow - seeks[0].startAt);
  check("late joiner can compute the current position", sd.state.phase === "playing" && Math.abs(heard - expected) < 5, `heard=${heard} expected=${expected}`);
  const members = await a.waitFor((m) => m.t === "members" && m.members.length === 4);
  check("existing members are told about the new member", members.members.some((m) => m.id === pid("dev-d")));

  console.log("Queue and next");
  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Song B", artist: "Artist", durMs: 180000 });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  a.send({ t: "next" });
  const p2 = await all([a, b, c, d], (x) => x.waitFor((m) => m.t === "prepare"));
  check("next prepares the second item", p2.every((p) => p.index === 1 && p.item.videoId === VIDEO_B));

  console.log("A device leaves while the barrier waits");
  c.close();
  await sleep(200);
  const epoch2 = p2[0].epoch;
  a.send({ t: "ready", epoch: epoch2 });
  b.send({ t: "ready", epoch: epoch2 });
  d.send({ t: "ready", epoch: epoch2 });
  const s2 = await all([a, b, d], (x) => x.waitFor((m) => m.t === "start"));
  check("start proceeds without the device that left", s2.every((s) => s.epoch === epoch2 && s.positionMs === 0));

  console.log("Early ended report is ignored");
  a.send({ t: "ended", epoch: epoch2 });
  check("ended before the item is over does not advance", await b.stays((m) => m.t === "prepare", 700));

  console.log("Removing the current item");
  a.send({ t: "queue.add", videoId: VIDEO_C, title: "Song C", artist: "Artist", durMs: 190000 });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 3);
  const stateNow = await (async () => {
    a.send({ t: "queue.move", id: "does-not-exist", toIndex: 0 }); // harmless no-op
    return null;
  })();
  void stateNow;
  // Remove the second item (currently playing): the third slides into its place and is prepared
  const list = await new Promise((resolve) => {
    const c2 = new Client(code, "dev-peek", "Peek");
    c2.join().then((s) => {
      c2.close();
      resolve(s.state.queue);
    });
  });
  const currentId = list[1].id;
  a.send({ t: "queue.remove", id: currentId });
  const p3 = await all([a, b, d], (x) => x.waitFor((m) => m.t === "prepare"));
  check("removing the playing item prepares the next one", p3.every((p) => p.item.videoId === VIDEO_C));

  console.log("Barrier timeout");
  const t0 = Date.now();
  const timeoutStart = await a.waitFor((m) => m.t === "start", 12000);
  const waited = timeoutStart._at - t0;
  check("nobody ready: the server starts anyway after about 8s", waited > 6500 && waited < 10500, `waited=${waited}ms`);

  await gaplessSection();
  await queueSection();
  await swapSection();
  await unplayableSection();
  await reconnectSection();
  await ghostSection(Number(process.env.SIM_STALE_MS) || 0);
  if (process.env.SIM_RELEASE) await updateSection(JSON.parse(process.env.SIM_RELEASE));
  await playlistAndRepeatSection();
  await autoplaySection();
  await crossfireSection();
  await conformanceSection();
  await soloAndPresenceSection(Number(process.env.SIM_STALE_MS) || 0);
  await shuffleSection();
  await shuffleModeSection();
  await existenceSection();
  await fullRoomSection();
  await ownerSection();
  await inviteSection();
  await avatarSection();
  await chatSection();
  if (process.env.SIM_STALE_MS) await staleSection(Number(process.env.SIM_STALE_MS));

  [a, b, d].forEach((x) => x.close());
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}


/** Gapless advance: devices that already moved on by themselves fix the next start time. */
async function gaplessSection() {
  console.log("Gapless advance");
  const { code } = await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json();
  const a = new Client(code, "g-a", "Anna");
  const b = new Client(code, "g-b", "Ben");
  await all([a, b], (x) => x.join());

  // Short items, so that "near the end" holds right after the start
  a.send({ t: "queue.add", videoId: VIDEO_A, title: "Short A", artist: "x", durMs: 3000 });
  const [pa] = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Short B", artist: "x", durMs: 3000 });
  const stateWithTwo = await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  await b.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  const nextId = stateWithTwo.state.queue[1].id;
  const epoch = pa.epoch;
  await all([a, b], (x) => x.send({ t: "ready", epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));

  a.send({ t: "advanced", epoch: epoch - 1, itemId: nextId, startedAt: Date.now() });
  a.send({ t: "advanced", epoch, itemId: "not-the-next-item", startedAt: Date.now() });
  a.send({ t: "advanced", epoch, itemId: nextId, startedAt: Date.now() - 60000 });
  check("advanced with wrong epoch, wrong item or an old start is ignored", await b.stays((m) => m.t === "advance", 500));

  const startedAt = Date.now() - 800;
  a.send({ t: "advanced", epoch, itemId: nextId, startedAt });
  const adv = await all([a, b], (x) => x.waitFor((m) => m.t === "advance"));
  check(
    "a valid advanced moves everyone to the next item at the reported time",
    adv.every((m) => m.index === 1 && m.epoch === epoch + 1 && m.startedAt === startedAt),
    JSON.stringify(adv[0]),
  );

  b.send({ t: "advanced", epoch, itemId: nextId, startedAt: Date.now() });
  check("a second report for the same transition is ignored", await a.stays((m) => m.t === "advance", 500));

  const late = new Client(code, "g-c", "Cara");
  const sl = await late.join();
  check(
    "a late joiner sees the advanced item playing from the reported start",
    sl.state.index === 1 && sl.state.phase === "playing" && sl.state.startedAt === startedAt && sl.state.epoch === epoch + 1,
    JSON.stringify(sl.state),
  );

  a.send({ t: "advanced", epoch: epoch + 1, itemId: nextId, startedAt: Date.now() });
  check("advanced past the last item is ignored", await b.stays((m) => m.t === "advance", 500));

  // An item that still has a long way to go must not be skipped by a bogus report
  const room2 = await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json();
  const x = new Client(room2.code, "g-x", "Xena");
  await x.join();
  x.send({ t: "queue.add", videoId: VIDEO_A, title: "Long", artist: "x", durMs: 200000 });
  const px = await x.waitFor((m) => m.t === "prepare");
  x.send({ t: "queue.add", videoId: VIDEO_B, title: "Next", artist: "x", durMs: 200000 });
  const sx = await x.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  x.send({ t: "ready", epoch: px.epoch });
  await x.waitFor((m) => m.t === "start");
  x.send({ t: "advanced", epoch: px.epoch, itemId: sx.state.queue[1].id, startedAt: Date.now() });
  check("advanced far from the end of the item is ignored", await x.stays((m) => m.t === "advance", 500));

  [a, b, late, x].forEach((c) => c.close());
}

/** The shared secret keeps strangers from creating rooms or joining them. */
async function authSection() {
  console.log("Shared secret");
  const noKey = await fetch(`${BASE}/rooms`, { method: "POST" });
  check("creating a room without the key is refused", noKey.status === 401, `status=${noKey.status}`);
  const wrongKey = await fetch(`${BASE}/rooms`, { method: "POST", headers: { "X-Sapoche-Key": "wrong" } });
  check("a wrong key is refused", wrongKey.status === 401, `status=${wrongKey.status}`);
  const right = await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders });
  check("the right key in a header is accepted", right.status === 200);
  const viaQuery = await fetch(`${BASE}/rooms${keyQuery}`, { method: "POST" });
  check("the right key in the query string is accepted", viaQuery.status === 200);
  const opened = await new Promise((resolve) => {
    const ws = new WebSocket(`${WS_BASE}/room/ABCDEF`); // no key
    ws.onopen = () => {
      ws.close();
      resolve(true);
    };
    ws.onerror = () => resolve(false);
  });
  check("a WebSocket connection without the key is refused", opened === false);
  const open = await fetch(`${BASE}/health`);
  check("/health stays open", open.status === 200);
}

async function freshRoom(names) {
  const { code } = await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json();
  const clients = names.map((n, i) => new Client(code, `${n}-id`, n));
  await all(clients, (c) => c.join());
  return clients;
}

/** Queue operations that a player UI needs: play next, jump to an item, clear. */
async function queueSection() {
  console.log("Queue operations");
  const [a, b] = await freshRoom(["Qa", "Qb"]);
  const add = (title, videoId, extra = {}) => a.send({ t: "queue.add", videoId, title, artist: "x", durMs: 200000, ...extra });
  const titles = (st) => st.state.queue.map((q) => q.title).join(",");

  add("A", VIDEO_A);
  const prep = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  await all([a, b], (x) => x.send({ t: "ready", epoch: prep[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));

  add("B", VIDEO_B);
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  add("C", VIDEO_C, { next: true });
  const withNext = await a.waitFor((m) => m.t === "state" && m.state.queue.length === 3);
  check("play next inserts right after the current item", titles(withNext) === "A,C,B", titles(withNext));
  check("adding does not disturb playback", withNext.state.phase === "playing" && withNext.state.index === 0);

  const idB = withNext.state.queue[2].id;
  a.send({ t: "jump", id: idB });
  const jumped = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("jump prepares the chosen item for everyone", jumped.every((p) => p.item.title === "B" && p.index === 2));

  a.send({ t: "jump", id: "no-such-item" });
  check("jump to an unknown item does nothing", await b.stays((m) => m.t === "prepare", 400));

  a.send({ t: "queue.clear" });
  const cleared = await all([a, b], (x) => x.waitFor((m) => m.t === "state" && m.state.queue.length === 0));
  check("clear empties the queue and stops playback", cleared.every((m) => m.state.phase === "idle"));

  // "Play next" on an idle room simply appends and starts
  add("D", VIDEO_A, { next: true });
  const restarted = await a.waitFor((m) => m.t === "prepare");
  check("adding to an emptied room starts it", restarted.item.title === "D" && restarted.index === 0);

  [a, b].forEach((x) => x.close());
}

/** A song and its video are two releases of one song: the queue item can change from one to the other. */
async function swapSection() {
  console.log("Swapping a song for its video");
  const [a, b] = await freshRoom(["Sa", "Sb"]);
  a.send({ t: "queue.add", videoId: VIDEO_A, title: "Song", artist: "x", durMs: 200000 });
  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Later", artist: "x", durMs: 200000 });
  const prep = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  await all([a, b], (x) => x.send({ t: "ready", epoch: prep[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  const queued = (await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2)).state.queue;
  const video = { videoId: VIDEO_C, title: "Song (Official Video)", artist: "x", durMs: 210000 };

  // An item still to come changes quietly, in its place
  a.send({ t: "queue.swap", id: queued[1].id, track: { ...video, title: "Later (Video)" } });
  const later = await b.waitFor((m) => m.t === "state" && m.state.queue[1]?.videoId === VIDEO_C);
  check("a song still to come is replaced in its place, keeping its id and who added it", later.state.queue[1].id === queued[1].id && later.state.queue[1].addedBy === pid("Sa-id") && later.state.queue[1].durMs === 210000);
  check("replacing a song to come does not disturb playback", later.state.phase === "playing" && later.state.index === 0 && await b.stays((m) => m.t === "prepare", 400));

  // The current one is prepared again for everyone, from about where it was
  await sleep(3200); // the start is 1.5 s ahead, then the song plays for a while
  a.send({ t: "queue.swap", id: queued[0].id, track: video });
  const again = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("swapping the current song prepares the other release for everyone", again.every((p) => p.item.videoId === VIDEO_C && p.index === 0 && p.item.id === queued[0].id && p.by === pid("Sa-id")));
  check("it carries on from the same moment", again[0].seekToMs >= 1000 && again[0].seekToMs < 6000, String(again[0].seekToMs));
  await all([a, b], (x) => x.send({ t: "ready", epoch: again[0].epoch }));
  const started = await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  check("and starts again once everyone is ready", started[0].positionMs === again[0].seekToMs);

  await sleep(200);
  a.inbox.length = 0; // leftovers of the change
  b.inbox.length = 0;
  a.send({ t: "queue.swap", id: queued[0].id, track: video });
  check("swapping for the same release does nothing", await b.stays((m) => m.t === "prepare" || m.t === "state", 400));
  a.send({ t: "queue.swap", id: "no-such-item", track: video });
  check("swapping an unknown item does nothing", await b.stays((m) => m.t === "prepare" || m.t === "state", 400));
  a.send({ t: "queue.swap", id: queued[0].id, track: { ...video, videoId: "bad" } });
  check("a bad video id is refused", (await a.waitFor((m) => m.t === "error")).code === "bad_video");

  [a, b].forEach((x) => x.close());
}

/** The app's own updates: a release in the private bucket is served to the key and to nobody else. */
async function updateSection({ apk, latest }) {
  console.log("App updates");
  const bytes = Buffer.from(apk, "base64");
  const url = (name) => `${BASE}/update/${name}`;
  if (KEY) check("the update info is refused without the key", (await fetch(url("latest.json"))).status === 401);
  if (KEY) check("the apk is refused without the key", (await fetch(url("sapoche-9.9.9.apk"))).status === 401);
  const info = await fetch(url("latest.json"), { headers: keyHeaders });
  const body = await info.json();
  check("latest.json says which version is newest", info.ok && body.versionCode === latest.versionCode && body.sha256 === latest.sha256 && body.size === bytes.length);
  check("and is never cached", info.headers.get("cache-control") === "no-cache");
  const whole = await fetch(url("sapoche-9.9.9.apk"), { headers: keyHeaders });
  const got = Buffer.from(await whole.arrayBuffer());
  check("the apk comes whole, as an apk", whole.status === 200 && got.equals(bytes) && whole.headers.get("content-type") === "application/vnd.android.package-archive");
  check("it says its length and that ranges work", whole.headers.get("content-length") === String(bytes.length) && whole.headers.get("accept-ranges") === "bytes");
  const rest = await fetch(url("sapoche-9.9.9.apk"), { headers: { ...keyHeaders, Range: "bytes=1000-" } });
  const tail = Buffer.from(await rest.arrayBuffer());
  check("a download that broke off goes on from where it was", rest.status === 206 && tail.equals(bytes.subarray(1000)) && rest.headers.get("content-range") === `bytes 1000-${bytes.length - 1}/${bytes.length}`, `${rest.status} ${rest.headers.get("content-range")}`);
  const middle = await fetch(url("sapoche-9.9.9.apk"), { headers: { ...keyHeaders, Range: "bytes=10-19" } });
  check("a slice of the middle comes as asked", middle.status === 206 && Buffer.from(await middle.arrayBuffer()).equals(bytes.subarray(10, 20)));
  const head = await fetch(url("sapoche-9.9.9.apk"), { method: "HEAD", headers: keyHeaders });
  check("HEAD gives the size without the file", head.status === 200 && head.headers.get("content-length") === String(bytes.length));
  check("a release that was never published is not found", (await fetch(url("sapoche-10.0.0.apk"), { headers: keyHeaders })).status === 404);
  // Apps up to 1.3.1 ask for app-<versionCode>.apk
  const old = await fetch(url("app-9.apk"), { headers: keyHeaders });
  check("an older app asking for app-<build number> gets the newest release", old.status === 200 && Buffer.from(await old.arrayBuffer()).equals(bytes));
  check("but not for a build that is not the newest", (await fetch(url("app-8.apk"), { headers: keyHeaders })).status === 404);
  check("other names are not served from the bucket", (await fetch(`${BASE}/update/..%2Flatest.json`, { headers: keyHeaders })).status === 404);
  check("nothing can be written through it", (await fetch(url("latest.json"), { method: "PUT", headers: keyHeaders, body: "{}" })).status === 405);
}

/** A device whose connection died without a word comes back: it must be listed once, not twice. */
async function reconnectSection() {
  console.log("A device reconnecting");
  const ids = (state) => state.members.map((x) => x.id).sort().join(",");
  const [a, b] = await freshRoom(["Ra", "Rb"]);
  const code = b.ws.url.split("/room/")[1].split("?")[0];
  // b's first connection stays open on the server's side, as a dead one does; b comes back on a new one
  const back = new Client(code, "Rb-id", "Rb");
  await back.join(false);
  const probe = new Client(code, "Rp-id", "Rp");
  const full = await probe.join(false);
  check("a device that came back on a new connection is listed once", full.members.filter((m) => m.id === pid("Rb-id")).length === 1, JSON.stringify(full.members));
  check("and nobody else was added or lost", ids(full) === ["Ra-id", "Rb-id", "Rp-id"].map(pid).sort().join(","), ids(full));
  check("the old connection was closed by the server", (await b.closed) === 1000);
  [a, back, probe].forEach((x) => x.close());
}

/** The same device under a new id (reinstalled): its silent old entry goes at once, a live one of the same name stays. */
async function ghostSection(staleMs) {
  if (!staleMs) return;
  console.log("A device that came back under another id");
  const [a, old] = await freshRoom(["Ga", "Gold"]);
  const code = old.ws.url.split("/room/")[1].split("?")[0];
  await sleep(staleMs + 400); // the old entry has been silent for longer than a live one ever is
  a.send({ t: "ping", c0: Date.now() }); // a, unlike the ghost, is still talking
  const fresh = new Client(code, "Gnew-id", "Gold");
  const state = await fresh.join(false);
  check("an old silent entry of the same name is not listed beside the new one", state.members.filter((m) => m.name === "Gold").length === 1 && state.members.some((m) => m.id === pid("Gnew-id")), JSON.stringify(state.members));
  check("the ghost's connection was closed", (await old.closed) === 1001);
  // Two live devices that happen to share a name are both kept
  const twin = new Client(code, "Gtwin-id", "Ga");
  a.send({ t: "ping", c0: Date.now() });
  const twinState = await twin.join(false);
  check("a live device of the same name is not touched", twinState.members.filter((m) => m.name === "Ga").length === 2, JSON.stringify(twinState.members));
  [a, fresh, twin].forEach((x) => x.close());
}

/** An item nobody can load is skipped instead of playing silence. */
async function unplayableSection() {
  console.log("Unplayable items");
  const [a, b] = await freshRoom(["Ua", "Ub"]);
  const add = (title, videoId) => a.send({ t: "queue.add", videoId, title, artist: "x", durMs: 200000 });

  add("Broken", VIDEO_A);
  const first = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  add("Fine", VIDEO_B);
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);

  a.send({ t: "resolveFailed", epoch: first[0].epoch, reason: "no stream" });
  check("one failure does not skip while the other is still loading", await b.stays((m) => m.t === "prepare" || m.t === "start", 400));
  b.send({ t: "resolveFailed", epoch: first[0].epoch, reason: "no stream" });
  const error = await a.waitFor((m) => m.t === "error" && m.code === "unplayable");
  check("when nobody can load an item, everyone is told", error.message.includes("Broken"));
  const second = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("and the next item is prepared", second.every((p) => p.item.title === "Fine" && p.index === 1));

  // Partial failure: playback still starts for those who loaded it
  a.send({ t: "resolveFailed", epoch: second[0].epoch, reason: "no stream" });
  b.send({ t: "ready", epoch: second[0].epoch });
  const started = await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  check("a failure on one device does not stop the others", started.every((s) => s.epoch === second[0].epoch));

  // Last item broken: the room goes idle
  add("Broken again", VIDEO_C);
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 3);
  a.send({ t: "next" });
  const third = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  a.send({ t: "resolveFailed", epoch: third[0].epoch });
  b.send({ t: "resolveFailed", epoch: third[0].epoch });
  const idle = await a.waitFor((m) => m.t === "state" && m.state.phase === "idle");
  check("with nothing left to play the room goes idle", idle.state.queue.length === 3);

  [a, b].forEach((x) => x.close());
}

async function newCode() {
  return (await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json()).code;
}

async function roomInfo(code) {
  return (await fetch(`${BASE}/room/${code}/info`, { headers: keyHeaders })).json();
}

/** A room is made on purpose: a mistyped code is an error, not an empty room, and an older app still works. */
async function existenceSection() {
  console.log("Room existence and info");
  const code = await newCode();
  check("a code nobody used has no room", (await roomInfo(code)).exists === false);

  const typo = new Client(code, "typo-id", "Typo");
  await typo.opened;
  typo.send({ t: "join", clientId: typo.clientId, name: typo.name, create: false });
  const refused = await typo.waitFor((m) => m.t === "error");
  check("joining an unknown code without creating is refused", refused.code === "room_not_found" && (await typo.closed) === 4004);
  check("a refused join leaves no room behind", (await roomInfo(code)).exists === false);

  const owner = new Client(code, "own-id", "Olga");
  const opened = await owner.join(true);
  check("create opens the room and its creator owns it", opened.state.ownerId === pid("own-id") && opened.members[0].owner === true);
  const guest = new Client(code, "gst-id", "Gus");
  const joined = await guest.join(false);
  check("joining a room that exists works", joined.state.ownerId === pid("own-id") && joined.members.length === 2);
  const info = await roomInfo(code);
  check("info tells whether the room exists and who is in it", info.exists === true && info.members === 2 && info.playing === false && info.name === null);
  if (KEY) {
    const noKey = await fetch(`${BASE}/room/${code}/info`);
    check("info needs the key too", noKey.status === 401, `status=${noKey.status}`);
  }

  const older = await newCode();
  const legacy = new Client(older, "old-id", "Old");
  await legacy.join();
  check("an older app that sends no create flag still opens the room", (await roomInfo(older)).exists === true);
  [owner, guest, legacy].forEach((x) => x.close());
}

/** A thirteenth device is told the room is full, and turned away for good. */
async function fullRoomSection() {
  console.log("Full room");
  const code = await newCode();
  const members = [];
  for (let i = 0; i < 12; i++) {
    const member = new Client(code, `full-${i}`, `M${i}`);
    await member.join(i === 0);
    members.push(member);
  }
  const extra = new Client(code, "full-extra", "Extra");
  await extra.opened;
  extra.send({ t: "join", clientId: extra.clientId, name: extra.name, create: false });
  const refused = await extra.waitFor((m) => m.t === "error");
  check("a device that finds the room full is told so and turned away", refused.code === "room_full" && (await extra.closed) === 1008);
  members.forEach((x) => x.close());
}

/** The owner names the room, restricts guests, removes people and hands the room over. */
async function ownerSection() {
  console.log("Owner and guests");
  const code = await newCode();
  const owner = new Client(code, "o-id", "Olga");
  await owner.join(true);
  const guest = new Client(code, "g-id", "Gus");
  const third = new Client(code, "t-id", "Tom");
  await guest.join(false);
  await third.join(false);
  const seen = (client, predicate) => client.waitFor((m) => m.t === "state" && predicate(m.state));
  const refuses = async (client, message) => {
    // The owner must have spoken a moment ago, or the short test timer would mark them away
    owner.send({ t: "ping", c0: Date.now() });
    await sleep(50);
    client.send(message);
    return (await client.waitFor((m) => m.t === "error")).code === "forbidden";
  };

  owner.send({ t: "room.name", name: "  Family  " });
  check("the owner names the room and everyone sees it", (await seen(guest, (s) => s.name === "Family")).state.name === "Family");
  check("a guest cannot change the settings", await refuses(guest, { t: "room.settings", guestControl: "add" }));

  owner.send({ t: "room.settings", guestControl: "add" });
  check("the owner restricts guests to adding songs", (await seen(guest, (s) => s.guestControl === "add")).state.guestControl === "add");
  guest.send({ t: "queue.add", videoId: VIDEO_A, title: "One", artist: "x", durMs: 200000 });
  const prepared = await owner.waitFor((m) => m.t === "prepare");
  check("a restricted guest can still add a song", prepared.item.title === "One");
  check("a restricted guest cannot pause", await refuses(guest, { t: "pause" }));
  check("a restricted guest cannot skip", await refuses(guest, { t: "next" }));
  check("a restricted guest cannot clear the queue", await refuses(guest, { t: "queue.clear" }));
  check("a restricted guest cannot swap a song for its video", await refuses(guest, { t: "queue.swap", id: prepared.item.id, track: { videoId: VIDEO_B, title: "One", artist: "x", durMs: 200000 } }));
  check("a restricted guest cannot rename the room", await refuses(guest, { t: "room.name", name: "Mine" }));
  guest.send({ t: "solo", on: true });
  const alone = await guest.waitFor((m) => m.t === "members" && m.members.find((x) => x.id === pid("g-id"))?.solo);
  check("a restricted guest can still listen on their own", alone.members.length === 3);
  guest.send({ t: "solo", on: false });
  await guest.waitFor((m) => m.t === "members" && !m.members.find((x) => x.id === pid("g-id"))?.solo);

  owner.send({ t: "repeat", mode: "all" });
  check("the owner still controls the room", (await seen(guest, (s) => s.repeat === "all")).state.repeat === "all");
  check("info shows what is playing", (await roomInfo(code)).title === "One");

  owner.close();
  await guest.waitFor((m) => m.t === "members" && !m.members.some((x) => x.id === pid("o-id")));
  guest.send({ t: "repeat", mode: "off" });
  check("with the owner away guests may control the room", (await seen(guest, (s) => s.repeat === "off")).state.repeat === "off");

  const owner2 = new Client(code, "o-id", "Olga");
  const back = await owner2.join(false);
  check("an owner who comes back is still the owner", back.state.ownerId === pid("o-id") && back.state.guestControl === "add");
  check("guests are held to the restriction again", await refuses(guest, { t: "pause" }));

  check("a guest cannot remove anyone", await refuses(guest, { t: "kick", id: pid("t-id") }));
  owner2.send({ t: "kick", id: pid("t-id") });
  const removed = await third.waitFor((m) => m.t === "error" && m.code === "removed");
  check("the owner removes a member", removed.code === "removed" && (await third.closed) === 4001);
  await guest.waitFor((m) => m.t === "members" && !m.members.some((x) => x.id === pid("t-id")));
  const again = new Client(code, "t-id", "Tom");
  check("a removed member may join again", (await again.join(false)).members.length === 3);

  owner2.send({ t: "bye" });
  const handed = await guest.waitFor((m) => m.t === "state" && m.state.ownerId !== pid("o-id"));
  check("an owner who leaves hands the room to whoever has been here longest", handed.state.ownerId === pid("g-id"));
  guest.send({ t: "bye" });
  await again.waitFor((m) => m.t === "state" && m.state.ownerId === pid("t-id"));
  again.send({ t: "bye" });
  await sleep(200);
  const late = new Client(code, "l-id", "Lea");
  const adopted = await late.join(false);
  check("a room everyone left has no owner until someone comes", adopted.state.ownerId === pid("l-id") && adopted.state.guestControl === "all");
  [owner2, guest, again, late].forEach((x) => x.close());
}

/** The invitation link and the address check for Android App Links are open to everyone. */
async function inviteSection() {
  console.log("Invitation link");
  const page = await fetch(`${BASE}/join/abcdef`);
  const html = await page.text();
  check("the invitation page opens without the key and shows the code", page.ok && html.includes("ABCDEF") && html.includes("intent://join/ABCDEF"));
  const vi = await fetch(`${BASE}/join/abcdef`, { headers: { "Accept-Language": "vi-VN,vi;q=0.9,en;q=0.5" } });
  const viHtml = await vi.text();
  check("a Vietnamese browser gets the page in Vietnamese, still with the code", viHtml.includes('lang="vi"') && viHtml.includes("Bạn được mời") && viHtml.includes("ABCDEF"));
  check("English is the page for any other language, and the page varies by language", html.includes('lang="en"') && (await fetch(`${BASE}/join/abcdef`, { headers: { "Accept-Language": "de" } }).then((r) => r.text())).includes('lang="en"') && vi.headers.get("vary") === "Accept-Language");
  check("the invitation page only accepts a room code", (await fetch(`${BASE}/join/abc`)).status === 404);
  const links = await (await fetch(`${BASE}/.well-known/assetlinks.json`)).json();
  check(
    "asset links name the app and its signing keys",
    links[0].target.package_name === "app.sapoche" && links[0].target.sha256_cert_fingerprints.length === 2,
  );
}

/** Pictures: kept by the server, announced by a fingerprint in the member list, fetched one at a time. */
async function avatarSection() {
  console.log("Pictures");
  const code = await newCode();
  const ann = new Client(code, "an-id", "Ann");
  await ann.join(true);
  const bob = new Client(code, "bo-id", "Bob");
  await bob.join(false);
  const picture = Buffer.from("a small picture, as far as the server can tell").toString("base64");
  const members = (client) => client.waitFor((m) => m.t === "members" && m.members.some((x) => x.id === pid("an-id") && x.av));

  ann.send({ t: "avatar.set", data: picture });
  const announced = await members(bob);
  const av = announced.members.find((x) => x.id === pid("an-id")).av;
  check("a picture is announced by a short fingerprint, not sent along", /^[0-9a-f]{8}$/.test(av) && !JSON.stringify(announced).includes(picture));
  bob.send({ t: "avatar.get", id: pid("an-id") });
  const got = await bob.waitFor((m) => m.t === "avatar");
  check("asking for it brings the picture and its fingerprint to the one who asked", got.id === pid("an-id") && got.av === av && got.data === picture);
  check("the others are not sent it", await ann.stays((m) => m.t === "avatar", 300));

  bob.send({ t: "avatar.get", id: pid("bo-id") });
  const none = await bob.waitFor((m) => m.t === "avatar");
  check("a member without a picture answers with none", none.id === pid("bo-id") && none.data === undefined && none.av === undefined);

  await sleep(100);
  bob.inbox.length = 0; // what was announced so far
  ann.send({ t: "avatar.set", data: "not base64 \u0000" });
  ann.send({ t: "avatar.set", data: "A".repeat(24_001) });
  check("a picture that is not base64, or too big, is ignored", await bob.stays((m) => m.t === "members", 300));

  const same = new Client(code, "an-id", "Ann");
  await same.join(false);
  await sleep(100);
  bob.inbox.length = 0; // the old socket of Ann closing
  same.send({ t: "avatar.set", data: picture });
  check("the same picture again changes nothing for the others", await bob.stays((m) => m.t === "members" && m.members.some((x) => x.id === pid("an-id") && x.av !== av), 300));
  same.send({ t: "avatar.set", data: null });
  const removed = await bob.waitFor((m) => m.t === "members" && m.members.some((x) => x.id === pid("an-id") && !x.av));
  check("taking the picture away is announced", removed.members.every((x) => !x.av));
  bob.send({ t: "avatar.get", id: pid("an-id") });
  check("and it cannot be fetched any more", (await bob.waitFor((m) => m.t === "avatar")).data === undefined);

  // A device that leaves takes its picture with it
  same.send({ t: "avatar.set", data: picture });
  await members(bob);
  same.close();
  await bob.waitFor((m) => m.t === "members" && !m.members.some((x) => x.id === pid("an-id")));
  bob.send({ t: "avatar.get", id: pid("an-id") });
  check("a picture does not outlive its member", (await bob.waitFor((m) => m.t === "avatar")).data === undefined);
  [ann, bob].forEach((x) => x.close());
}

/** Chat: kept for whoever joins later, sent to everybody; reactions: passed on to the others, never kept. */
async function chatSection() {
  console.log("Chat and reactions");
  const code = await newCode();
  const ann = new Client(code, "chat-an", "Ann");
  await ann.join(true);
  const empty = await ann.waitFor((m) => m.t === "chat.history");
  check("a new room has no chat yet, and says so right after the state", Array.isArray(empty.msgs) && empty.msgs.length === 0);
  const bob = new Client(code, "chat-bo", "Bob");
  await bob.join(false);
  await bob.waitFor((m) => m.t === "chat.history");

  ann.send({ t: "chat", text: "  hello there  ", cid: "c-1" });
  const [toAnn, toBob] = await all([ann, bob], (x) => x.waitFor((m) => m.t === "chat"));
  check(
    "a message reaches everybody, its sender too, trimmed and signed with the public id and name",
    toAnn.msg.text === "hello there" && toBob.msg.text === "hello there" && toBob.msg.by === pid("chat-an") && toBob.msg.name === "Ann",
    JSON.stringify(toBob),
  );
  check("it carries the room's number for it, its time and the sender's own id for it", toAnn.msg.id === 1 && Math.abs(toAnn.msg.at - Date.now()) < 3000 && toAnn.msg.cid === "c-1");
  check("the secret client id never goes out with it", !JSON.stringify(toBob).includes("chat-an\""));

  ann.send({ t: "chat", text: "   " });
  ann.send({ t: "chat", text: 42 });
  ann.send({ t: "chat" });
  check("a message with no text is ignored", await bob.stays((m) => m.t === "chat", 400));

  bob.send({ t: "chat", text: "x".repeat(499) + "\u{1F600}\u{1F600}" });
  const long = await ann.waitFor((m) => m.t === "chat");
  check("a long message is cut to 500 characters without splitting an emoji", Array.from(long.msg.text).length === 500 && long.msg.text.endsWith("\u{1F600}") && long.msg.id === 2 && long.msg.cid === undefined);

  // A guest who may only add songs can still talk
  ann.send({ t: "room.settings", guestControl: "add" });
  await bob.waitFor((m) => m.t === "state" && m.state.guestControl === "add");
  bob.send({ t: "chat", text: "still here" });
  const guest = await ann.waitFor((m) => m.t === "chat");
  check("guests limited to adding songs can still chat", guest.msg.text === "still here");
  check("and get no forbidden error for it", await bob.stays((m) => m.t === "error", 300));

  const cara = new Client(code, "chat-ca", "Cara");
  await cara.join(false);
  const history = await cara.waitFor((m) => m.t === "chat.history");
  check("whoever joins later gets the messages so far, oldest first", history.msgs.map((m) => m.id).join(",") === "1,2,3", JSON.stringify(history.msgs.map((m) => m.id)));

  console.log("Reactions");
  ann.send({ t: "react", e: "heart", n: 3 });
  const [rb, rc] = await all([bob, cara], (x) => x.waitFor((m) => m.t === "react"));
  check("a reaction reaches the others with who sent it and how many", rb.by === pid("chat-an") && rb.e === "heart" && rb.n === 3 && rc.n === 3);
  check("but not its sender, who already showed it", await ann.stays((m) => m.t === "react", 300));
  bob.send({ t: "react", e: "fire", n: 500 });
  check("a count is capped", (await ann.waitFor((m) => m.t === "react")).n === 10);
  bob.send({ t: "react", e: "fire" });
  check("no count means one", (await ann.waitFor((m) => m.t === "react")).n === 1);
  bob.send({ t: "react", e: "guitar", n: 2 });
  const more = await ann.waitFor((m) => m.t === "react");
  check("the fuller set of reactions is passed on too", more.e === "guitar" && more.n === 2);
  for (const e of ["🍕", "👍🏽", "🇻🇳", "👨‍👩‍👧‍👦", "1️⃣"]) {
    bob.send({ t: "react", e });
    check(`any emoji of a keyboard is passed on: ${e}`, (await ann.waitFor((m) => m.t === "react")).e === e);
  }
  for (const e of ["poop", "12", "#", "a🍕", "🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕🍕", "<b>🍕</b>"]) bob.send({ t: "react", e });
  check("but not text, digits alone or a long string of them", await ann.stays((m) => m.t === "react", 300));
  bob.send({ t: "react", e: "poop" });
  bob.send({ t: "react", e: "toString" });
  bob.send({ t: "react", e: "fire", n: 1.5 });
  const odd = await ann.waitFor((m) => m.t === "react");
  check("an unknown reaction is ignored, and a count that is not whole counts as one", odd.e === "fire" && odd.n === 1);
  check("only that one came", await ann.stays((m) => m.t === "react", 300));

  const late = new Client(code, "chat-da", "Dan");
  await late.join(false);
  const kept = await late.waitFor((m) => m.t === "chat.history");
  check("reactions are not kept in the history", kept.msgs.length === 3);

  // Only the last messages are kept
  for (let i = 0; i < 100; i++) {
    ann.send({ t: "chat", text: `m${i}` });
    if (i % 15 === 14) await sleep(1000); // under the limit of 20 messages a second
  }
  await ann.waitFor((m) => m.t === "chat" && m.msg.text === "m99", 8000);
  const eve = new Client(code, "chat-ev", "Eve");
  await eve.join(false);
  const last = await eve.waitFor((m) => m.t === "chat.history");
  check("the room keeps the last 100 messages", last.msgs.length === 100 && last.msgs[0].id === 4 && last.msgs[99].text === "m99", `${last.msgs.length} ${last.msgs[0]?.id}`);

  // A member who left keeps their name on what they wrote
  ann.close();
  await bob.waitFor((m) => m.t === "members" && !m.members.some((x) => x.id === pid("chat-an")));
  const fay = new Client(code, "chat-fa", "Fay");
  await fay.join(false);
  const after = await fay.waitFor((m) => m.t === "chat.history");
  check("messages keep their sender's name after they leave", after.msgs.at(-1).name === "Ann");
  [bob, cara, late, eve, fay].forEach((x) => x.close());
}

/** How long empty rooms live and whether dead connections are noticed. Needs the short timers of `npm test`. */
async function lifetimeSection() {
  console.log("Room lifetime");
  const bare = await newCode();
  const first = new Client(bare, "b-id", "Bee");
  await first.join(true);
  first.send({ t: "chat", text: "anyone?" });
  await first.waitFor((m) => m.t === "chat");
  first.close();
  await sleep(500);
  check("an empty room with nothing queued is kept for a moment", (await roomInfo(bare)).exists === true);
  await sleep(1800);
  check("and is gone after its short lifetime", (await roomInfo(bare)).exists === false);
  const again = new Client(bare, "b-id", "Bee");
  await again.join(true);
  check("its chat went with it", (await again.waitFor((m) => m.t === "chat.history")).msgs.length === 0);
  again.close();

  const kept = await newCode();
  const second = new Client(kept, "k-id", "Kay");
  await second.join(true);
  second.send({ t: "queue.add", videoId: VIDEO_A, title: "Keep", artist: "x", durMs: 200000 });
  await second.waitFor((m) => m.t === "prepare");
  second.close();
  await sleep(3000);
  check("an empty room with songs queued is kept longer", (await roomInfo(kept)).exists === true);
  await sleep(4000);
  check("and goes too in the end", (await roomInfo(kept)).exists === false);

  const dead = await newCode();
  const ghost = new Client(dead, "z-id", "Zed");
  await ghost.join(true); // and never speaks again
  const code = await Promise.race([ghost.closed, sleep(7000).then(() => null)]);
  check("a connection that went silent is dropped even when nobody speaks", code === 1001, `close code ${code}`);
  await sleep(2500);
  check("and its room is cleaned up after it", (await roomInfo(dead)).exists === false);
}

/** A device that went silent (dead battery, out of range) must not make the room wait at every track. */
async function staleSection(staleMs) {
  console.log("Silent devices");
  const [a, b, ghost] = await freshRoom(["Sa", "Sb", "Sghost"]);
  a.send({ t: "queue.add", videoId: VIDEO_A, title: "One", artist: "x", durMs: 200000 });
  const first = await all([a, b, ghost], (x) => x.waitFor((m) => m.t === "prepare"));
  await all([a, b], (x) => x.send({ t: "ready", epoch: first[0].epoch }));
  // The ghost never answers, but it spoke a moment ago so the room still waits for it
  check("a device that only just spoke is still waited for", await a.stays((m) => m.t === "start", 500));
  await sleep(staleMs + 300);
  // Anyone speaking triggers no re-check by itself, so ask for the next track: the ghost has been silent for too long
  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Two", artist: "x", durMs: 200000 });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  a.send({ t: "next" });
  const second = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  const t0 = Date.now();
  await all([a, b], (x) => x.send({ t: "ready", epoch: second[0].epoch }));
  const start = await a.waitFor((m) => m.t === "start", 4000);
  check("a silent device no longer holds the barrier", start._at - t0 < 1500, `waited ${start._at - t0}ms`);
  [a, b, ghost].forEach((x) => x.close());
}

/** Shuffling what is to come, shuffling a finished list, and play meaning "again" at the end. */
async function shuffleSection() {
  console.log("Shuffle and replay");
  const [a, b] = await freshRoom(["Ha", "Hb"]);
  const names = Array.from({ length: 12 }, (_, i) => `Song ${i}`);
  a.send({ t: "queue.addMany", tracks: names.map((title) => ({ videoId: VIDEO_A, title, artist: "x", durMs: 200000 })) });
  const first = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  await all([a, b], (x) => x.send({ t: "ready", epoch: first[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  const before = (await a.waitFor((m) => m.t === "state" && m.state.queue.length === 12)).state.queue;

  a.send({ t: "queue.shuffle" });
  const after = (await b.waitFor((m) => m.t === "state" && m.state.queue.length === 12 && m.state.queue.map((q) => q.id).join() !== before.map((q) => q.id).join())).state.queue;
  check("shuffle keeps the same songs", after.map((q) => q.id).sort().join() === before.map((q) => q.id).sort().join());
  check("shuffle leaves the current song where it was", after[0].id === before[0].id);
  check("shuffle changes the order of what is to come", after.slice(1).map((q) => q.id).join() !== before.slice(1).map((q) => q.id).join());

  // Play through to the end: put the room at the last song and let it finish
  const last = after[after.length - 1];
  a.send({ t: "jump", id: last.id });
  const p = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare" && m.item.id === last.id));
  await all([a, b], (x) => x.send({ t: "ready", epoch: p[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  a.send({ t: "next" });
  const idle = await a.waitFor((m) => m.t === "state" && m.state.phase === "idle");
  check("the room goes idle after the last song", idle.state.index === 11);

  a.send({ t: "play" });
  const again = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("play after the last song starts the list again from the top", again[0].index === 0 && again[0].by === pid("Ha-id"));

  // Finish again, then shuffle the finished list
  await all([a, b], (x) => x.send({ t: "ready", epoch: again[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  a.send({ t: "queue.clear" });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 0);
  a.send({ t: "queue.shuffle" });
  check("shuffling an empty queue does nothing", await b.stays((m) => m.t === "prepare", 500));

  [a, b].forEach((x) => x.close());
}

/** Shuffle as a mode: on mixes what is to come and keeps mixing what is added, off puts the songs back in their order. */
async function shuffleModeSection() {
  console.log("Shuffle mode");
  const [a, b] = await freshRoom(["Ma", "Mb"]);
  const ids = (m) => m.state.queue.map((q) => q.id).join();
  const titles = Array.from({ length: 12 }, (_, i) => `Song ${i}`);
  a.send({ t: "queue.addMany", tracks: titles.map((title) => ({ videoId: VIDEO_A, title, artist: "x", durMs: 200000 })) });
  const first = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  await all([a, b], (x) => x.send({ t: "ready", epoch: first[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  const before = await a.waitFor((m) => m.t === "state" && m.state.queue.length === 12);
  check("a new room has shuffle off", before.state.shuffle === false);
  check("and its remembered order is not sent to anybody", !("shuffleOrder" in before.state));

  b.send({ t: "shuffle", on: true });
  const on = await a.waitFor((m) => m.t === "state" && m.state.shuffle === true);
  check("a guest can turn shuffle on for the room", on.state.shuffle === true);
  check("turning it on mixes what is to come", ids(on) !== ids(before));
  check("and leaves the same songs, the current one in place", on.state.queue.map((q) => q.id).sort().join() === before.state.queue.map((q) => q.id).sort().join() && on.state.queue[0].id === before.state.queue[0].id);
  check("the remembered order stays private", !("shuffleOrder" in on.state));

  a.send({ t: "shuffle", on: "yes" });
  check("anything but true or false is ignored", await a.stays((m) => m.t === "state", 300));

  // A song added at the end is mixed in among those to come, and one added to play next stays next
  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Added", artist: "x", durMs: 200000 });
  const added = await b.waitFor((m) => m.t === "state" && m.state.queue.length === 13);
  const at = added.state.queue.findIndex((q) => q.title === "Added");
  check("a song added meanwhile is somewhere among those to come", at >= 1);
  a.send({ t: "queue.add", videoId: VIDEO_C, title: "Next up", artist: "x", durMs: 200000, next: true });
  const next = await b.waitFor((m) => m.t === "state" && m.state.queue.length === 14);
  check("one added to play next stays next", next.state.queue[1].title === "Next up");

  [a, b].forEach((x) => (x.inbox.length = 0));
  a.send({ t: "shuffle", on: false });
  const off = await b.waitFor((m) => m.t === "state" && m.state.shuffle === false);
  const titlesOff = off.state.queue.map((q) => q.title);
  check("turning it off keeps the current song first", titlesOff[0] === "Song 0");
  const original = titlesOff.slice(1).filter((t) => t.startsWith("Song "));
  check("and puts the songs back in the order they had", original.join() === titles.slice(1).join());
  check("songs added while it was on follow them", titlesOff.slice(-2).sort().join() === ["Added", "Next up"].join(), titlesOff.join("|"));
  [a, b].forEach((x) => (x.inbox.length = 0));

  // Off with nothing remembered is harmless, and the old one-shot message still works
  await a.waitFor((m) => m.t === "state" && m.state.shuffle === false);
  [a, b].forEach((x) => (x.inbox.length = 0));
  a.send({ t: "shuffle", on: false });
  check("turning it off again does nothing", await a.stays((m) => m.t === "state", 300));
  a.send({ t: "queue.shuffle" });
  const mixed = await b.waitFor((m) => m.t === "state" && ids(m) !== ids(off));
  check("the one-shot shuffle still mixes without turning the mode on", mixed.state.shuffle === false);

  // Guests restricted to adding cannot turn it on
  a.send({ t: "room.settings", guestControl: "add" });
  await b.waitFor((m) => m.t === "state" && m.state.guestControl === "add");
  b.send({ t: "shuffle", on: true });
  const denied = await b.waitFor((m) => m.t === "error");
  check("a guest who may only add songs cannot turn it on", denied.code === "forbidden");

  [a, b].forEach((x) => x.close());
}

/** Keeps the given clients speaking, as a real device does with its pings. Returns a function that stops it. */
function keepAlive(clients) {
  const timer = setInterval(() => clients.forEach((c) => c.send({ t: "ping", c0: Date.now() })), 400);
  return () => clearInterval(timer);
}

/** Listening on one's own, who caused a pause or a skip, asking for the state again, and quiet devices. */
async function soloAndPresenceSection(staleMs) {
  console.log("Solo, resync and presence");
  const [a, b, c] = await freshRoom(["Xa", "Xb", "Xc"]);
  const stopAlive = keepAlive([a, b]);
  const member = (msg, id) => msg.members.find((m) => m.id === id);

  check("members start out present and following", member(await a.waitFor((m) => m.t === "members" && m.members.length === 3), pid("Xc-id")).solo === false);

  c.send({ t: "solo", on: true });
  const soloMsg = await a.waitFor((m) => m.t === "members" && member(m, pid("Xc-id"))?.solo === true);
  check("the others are told a device listens on its own", !!soloMsg);

  a.send({ t: "queue.add", videoId: VIDEO_A, title: "One", artist: "x", durMs: 200000 });
  const first = await all([a, b, c], (x) => x.waitFor((m) => m.t === "prepare"));
  check("the queue starting by itself names nobody", first[0].by === undefined);
  const t0 = Date.now();
  await all([a, b], (x) => x.send({ t: "ready", epoch: first[0].epoch }));
  const start = await a.waitFor((m) => m.t === "start", 4000);
  check("a device listening on its own does not hold the barrier", start._at - t0 < 1500, `waited ${start._at - t0}ms`);

  b.send({ t: "pause" });
  const paused = await a.waitFor((m) => m.t === "pause");
  check("a pause says who paused", paused.by === pid("Xb-id"), `by=${paused.by}`);
  b.send({ t: "play" });
  const resumed = await a.waitFor((m) => m.t === "start");
  check("a resume says who resumed", resumed.by === pid("Xb-id"));

  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Two", artist: "x", durMs: 200000 });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  a.send({ t: "next" });
  const skipped = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("a skip says who skipped", skipped[0].by === pid("Xa-id"));

  // c missed nothing on purpose here, but asks again as it would when rejoining
  c.inbox.length = 0; // whatever it heard so far must not be mistaken for the answer
  c.send({ t: "resync" });
  const state = await c.waitFor((m) => m.t === "state");
  check("resync returns the room's state", state.state.queue.length === 2 && state.state.index === 1);
  const again = await c.waitFor((m) => m.t === "prepare", 1500);
  check("resync during a barrier also returns the prepare", again.item.videoId === VIDEO_B && again.epoch === skipped[0].epoch);

  c.send({ t: "solo", on: false });
  check("the device is following again", !!(await a.waitFor((m) => m.t === "members" && member(m, pid("Xc-id"))?.solo === false)));

  if (staleMs > 0) {
    await sleep(staleMs + 400);
    const away = await a.waitFor((m) => m.t === "members" && member(m, pid("Xc-id"))?.away === true, 3000);
    check("a device that went quiet is marked away", !!away);
    c.send({ t: "ping", c0: Date.now() });
    const back = await a.waitFor((m) => m.t === "members" && member(m, pid("Xc-id"))?.away === false, 3000);
    check("and is marked present again as soon as it speaks", !!back);
  }

  stopAlive();
  [a, b, c].forEach((x) => x.close());
}

/** Adding a playlist in one message, and the three repeat modes. */
async function playlistAndRepeatSection() {
  console.log("Playlist and repeat");
  const [a, b] = await freshRoom(["Pa", "Pb"]);
  const track = (videoId, title) => ({ videoId, title, artist: "x", durMs: 200000 });

  a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One"), { videoId: "bad", title: "Bad" }, track(VIDEO_B, "Two"), track(VIDEO_C, "Three")] });
  const first = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  const withAll = await a.waitFor((m) => m.t === "state" && m.state.queue.length === 3);
  check("a playlist arrives in order and invalid entries are dropped", withAll.state.queue.map((q) => q.title).join() === "One,Two,Three");
  check("adding to an idle room starts the first added item", first[0].item.title === "One");

  a.send({ t: "queue.addMany", tracks: [track(VIDEO_B, "Next A"), track(VIDEO_C, "Next B")], next: true });
  const placed = await a.waitFor((m) => m.t === "state" && m.state.queue.length === 5);
  check("playlist added as next lands right after the current item", placed.state.queue.map((q) => q.title).join() === "One,Next A,Next B,Two,Three");

  const big = Array.from({ length: 150 }, (_, i) => track(VIDEO_A, `Song ${i}`));
  a.send({ t: "queue.addMany", tracks: big });
  const capped = await a.waitFor((m) => m.t === "state" && m.state.queue.length === 105);
  check("one message adds at most 100 songs", capped.state.queue.length === 105);

  a.send({ t: "queue.clear" });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 0);
  check("repeat defaults to off", capped.state.repeat === "off");

  // Repeat one: the same item plays again through a barrier
  a.send({ t: "queue.addMany", tracks: [{ ...track(VIDEO_A, "Short"), durMs: 6000 }, track(VIDEO_B, "Other")] });
  const p1 = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  a.send({ t: "repeat", mode: "one" });
  const one = await a.waitFor((m) => m.t === "state" && m.state.repeat === "one");
  check("repeat mode is broadcast", one.state.repeat === "one");
  await all([a, b], (x) => x.send({ t: "ready", epoch: p1[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  a.send({ t: "advanced", epoch: p1[0].epoch, itemId: one.state.queue[1].id, startedAt: Date.now() });
  check("a gapless advance is ignored while repeating one", await a.stays((m) => m.t === "advance", 500));
  await sleep(5200); // past the item's expected end
  a.send({ t: "ended", epoch: p1[0].epoch });
  const again = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare", 4000));
  check("repeat one prepares the same item again", again[0].item.title === "Short" && again[0].index === 0);

  // The next button still moves on, and repeat all wraps around at the end of the queue
  await all([a, b], (x) => x.send({ t: "ready", epoch: again[0].epoch }));
  await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
  a.send({ t: "next" });
  const second = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("next skips ahead even with repeat one", second[0].item.title === "Other");
  a.send({ t: "repeat", mode: "all" });
  await a.waitFor((m) => m.t === "state" && m.state.repeat === "all");
  a.send({ t: "next" });
  const wrapped = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("repeat all wraps to the first item after the last", wrapped[0].item.title === "Short" && wrapped[0].index === 0);

  a.send({ t: "repeat", mode: "off" });
  await a.waitFor((m) => m.t === "state" && m.state.repeat === "off");
  await sleep(200);
  a.inbox.length = 0; // leftovers of the earlier track changes
  a.send({ t: "repeat", mode: "sideways" });
  check("an unknown repeat mode is ignored", await a.stays((m) => m.t === "state", 300));
  [a, b].forEach((x) => x.close());
}

/** Autoplay: when the queue runs out one device is asked for more songs; the setting belongs to the room. */
async function autoplaySection() {
  console.log("Autoplay");
  const [a, b] = await freshRoom(["Ua", "Ub"]); // Ua came first, so it owns the room
  const track = (videoId, title) => ({ videoId, title, artist: "x", durMs: 200000 });
  const quiet = () => [a, b].forEach((x) => (x.inbox.length = 0));
  /** Everybody who follows the room has the item loaded and the room plays. */
  const playing = async (followers) => {
    const p = await all(followers, (x) => x.waitFor((m) => m.t === "prepare"));
    await all(followers, (x) => x.send({ t: "ready", epoch: p[0].epoch }));
    await all(followers, (x) => x.waitFor((m) => m.t === "start"));
    return p[0];
  };

  a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
  await playing([a, b]);
  quiet();
  b.send({ t: "next" });
  const idle = await a.waitFor((m) => m.t === "state" && m.state.phase === "idle");
  check("autoplay is on in a new room", idle.state.autoplay === true);
  const ask = await a.waitFor((m) => m.t === "autoplay.fill");
  check("when the queue runs out the owner's device is asked for songs like the last one", ask.videoId === VIDEO_A && ask.title === "One" && ask.epoch === idle.state.epoch);
  check("and nobody else is", await b.stays((m) => m.t === "autoplay.fill", 300));

  a.send({ t: "queue.addMany", tracks: [track(VIDEO_B, "Two"), track(VIDEO_C, "Three")] });
  const filled = await playing([a, b]);
  check("the songs it sends start playing after the ones already there", filled.item.title === "Two" && filled.index === 1);

  // The setting is the room's: a guest turns it off as they would repeat, and then nobody is asked
  quiet();
  b.send({ t: "autoplay", on: false });
  const off = await a.waitFor((m) => m.t === "state" && m.state.autoplay === false);
  check("a guest can turn autoplay off for the room", off.state.autoplay === false);
  a.send({ t: "autoplay", on: "yes" });
  check("anything but true or false is ignored", await a.stays((m) => m.t === "state", 300));
  a.send({ t: "next" });
  await playing([a, b]);
  quiet();
  a.send({ t: "next" });
  await a.waitFor((m) => m.t === "state" && m.state.phase === "idle");
  check("with autoplay off nobody is asked", (await a.stays((m) => m.t === "autoplay.fill", 400)) && (await b.stays((m) => m.t === "autoplay.fill", 100)));

  // A device listening on its own is asked only when nobody else is here to ask
  b.send({ t: "autoplay", on: true });
  await a.waitFor((m) => m.t === "state" && m.state.autoplay === true);
  a.send({ t: "solo", on: true });
  b.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "Four")] });
  await playing([b]);
  quiet();
  b.send({ t: "next" });
  await b.waitFor((m) => m.t === "autoplay.fill");
  check("a device listening alone is passed over for one that follows the room", await a.stays((m) => m.t === "autoplay.fill", 300));

  // A song nobody could play does not ask for more, or a run of broken songs would never end
  b.send({ t: "queue.addMany", tracks: [track(VIDEO_B, "Five")] });
  const five = await b.waitFor((m) => m.t === "prepare");
  quiet();
  b.send({ t: "resolveFailed", epoch: five.epoch });
  await b.waitFor((m) => m.t === "state" && m.state.phase === "idle");
  check("a song nobody could play does not ask for more", await b.stays((m) => m.t === "autoplay.fill", 400));

  // Like repeat, it is the owner's alone once guests may only add songs
  a.send({ t: "solo", on: false });
  a.send({ t: "room.settings", guestControl: "add" });
  await b.waitFor((m) => m.t === "state" && m.state.guestControl === "add");
  quiet();
  b.send({ t: "autoplay", on: false });
  const refused = await b.waitFor((m) => m.t === "error");
  check("guests that may only add songs cannot change it", refused.code === "forbidden");
  [a, b].forEach((x) => x.close());
}

/**
 * Things happening at the same time or at awkward moments, the way public sync suites sweep them (Syncplay's "crossfire",
 * pause during a song change, peers joining and leaving mid-barrier): the room must end up in one state that everybody agrees on.
 */
async function crossfireSection() {
  console.log("Crossfire and awkward moments");
  const track = (videoId, title, extra = {}) => ({ videoId, title, artist: "x", durMs: 200000, ...extra });
  const quiet = (clients) => clients.forEach((x) => (x.inbox.length = 0));
  /** What every device would be told if it asked now. */
  const views = async (clients) => {
    quiet(clients);
    clients.forEach((x) => x.send({ t: "resync" }));
    return all(clients, (x) => x.waitFor((m) => m.t === "state"));
  };
  const agree = (states) => states.every((m) => m.state.phase === states[0].state.phase && m.state.epoch === states[0].state.epoch && m.state.index === states[0].state.index);

  // Pause while the room is still loading the song: it must not start behind the person's back
  {
    const [a, b] = await freshRoom(["Xa", "Xb"]);
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One"), track(VIDEO_B, "Two")] });
    const p = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    quiet([a, b]);
    b.send({ t: "pause" });
    const paused = await a.waitFor((m) => m.t === "pause" || (m.t === "state" && m.state.phase === "paused"), 1500).catch(() => null);
    check("pausing while the song is still loading pauses the room", !!paused);
    await all([a, b], (x) => x.send({ t: "ready", epoch: p[0].epoch }));
    check("and the song does not start once everybody is ready", await a.stays((m) => m.t === "start", 700));
    a.send({ t: "play" });
    const start = await all([a, b], (x) => x.waitFor((m) => m.t === "start", 3000)).catch(() => null);
    check("play then starts it for everybody, from where it was", !!start && start[0].startAt === start[1].startAt && start[0].positionMs === 0);
    [a, b].forEach((x) => x.close());
  }

  // A pause and a play at the same moment: whoever the server heard last wins, and everybody is told the same
  {
    const [a, b, c] = await freshRoom(["Ya", "Yb", "Yc"]);
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    const p = await all([a, b, c], (x) => x.waitFor((m) => m.t === "prepare"));
    await all([a, b, c], (x) => x.send({ t: "ready", epoch: p[0].epoch }));
    await all([a, b, c], (x) => x.waitFor((m) => m.t === "start"));
    for (const gap of [0, 5, 40, 150]) {
      a.send({ t: "pause" });
      if (gap) await sleep(gap);
      b.send({ t: "play" });
      await sleep(400);
      const seen = await views([a, b, c]);
      check(`pause and play ${gap} ms apart leave the three devices in one state`, agree(seen), JSON.stringify(seen.map((m) => [m.state.phase, m.state.epoch])));
      // Put the room back to playing for the next round
      if (seen[0].state.phase === "paused") {
        a.send({ t: "play" });
        await sleep(200);
      }
    }
    [a, b, c].forEach((x) => x.close());
  }

  // Twelve devices through one barrier, each ready at its own pace
  {
    const names = Array.from({ length: 12 }, (_, i) => `Z${i}`);
    const clients = await freshRoom(names);
    clients[0].send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    const p = await all(clients, (x) => x.waitFor((m) => m.t === "prepare"));
    await Promise.all(clients.map(async (x, i) => { await sleep((i * 37) % 400); x.send({ t: "ready", epoch: p[0].epoch }); }));
    const starts = await all(clients, (x) => x.waitFor((m) => m.t === "start", 3000));
    check("twelve devices with different loading times get one and the same start", starts.every((st) => st.startAt === starts[0].startAt && st.epoch === starts[0].epoch));
    clients.forEach((x) => x.close());
  }

  // A device that joins in the middle of a barrier is waited for
  {
    const [a, b] = await freshRoom(["Wa", "Wb"]);
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    const p = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    const late = new Client(p[0] && a.ws.url.split("/room/")[1].split("?")[0], "Wc-id", "Wc");
    await late.join();
    const again = await late.waitFor((m) => m.t === "prepare");
    check("a device joining mid-barrier is told to prepare the same song", again.epoch === p[0].epoch && again.item.title === "One");
    await all([a, b], (x) => x.send({ t: "ready", epoch: p[0].epoch }));
    check("and the barrier waits for it", await a.stays((m) => m.t === "start", 500));
    late.send({ t: "ready", epoch: p[0].epoch });
    const go = await all([a, b, late], (x) => x.waitFor((m) => m.t === "start", 2000));
    check("then starts for all three together", go.every((st) => st.startAt === go[0].startAt));
    [a, b, late].forEach((x) => x.close());
  }

  // A ready for an earlier song must not release the barrier of the next
  {
    const [a, b] = await freshRoom(["Va", "Vb"]);
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One"), track(VIDEO_B, "Two")] });
    const first = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    a.send({ t: "next" });
    const second = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare" && m.epoch !== first[0].epoch));
    quiet([a, b]);
    await all([a, b], (x) => x.send({ t: "ready", epoch: first[0].epoch }));
    check("a ready for the song before does not start the next one", await a.stays((m) => m.t === "start", 600));
    await all([a, b], (x) => x.send({ t: "ready", epoch: second[0].epoch }));
    check("the ready for the right song does", !!(await a.waitFor((m) => m.t === "start", 2000).catch(() => null)));
    [a, b].forEach((x) => x.close());
  }

  // Everybody leaves in the middle of a song: nothing keeps running, and the room waits where it was
  {
    const [a, b] = await freshRoom(["Ua2", "Ub2"]);
    const code = a.ws.url.split("/room/")[1].split("?")[0];
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    const p = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    await all([a, b], (x) => x.send({ t: "ready", epoch: p[0].epoch }));
    await all([a, b], (x) => x.waitFor((m) => m.t === "start"));
    await sleep(1800);
    [a, b].forEach((x) => x.close());
    await sleep(300);
    const back = new Client(code, "Ua2-id", "Ua2");
    const st = await back.join(false);
    check("a room left in the middle of a song is paused when somebody comes back", st.state.phase === "paused" && st.state.positionMs > 0 && st.state.queue.length === 1, JSON.stringify([st.state.phase, st.state.positionMs]));
    back.close();
  }

  // The queue has a limit, and a flood of messages is slowed without hurting the room
  {
    const [a, b] = await freshRoom(["Qa2", "Qb2"]);
    const hundred = Array.from({ length: 100 }, (_, i) => track(VIDEO_A, `Song ${i}`));
    a.send({ t: "queue.addMany", tracks: hundred });
    await a.waitFor((m) => m.t === "state" && m.state.queue.length === 100);
    await sleep(300);
    a.send({ t: "queue.addMany", tracks: hundred });
    await a.waitFor((m) => m.t === "state" && m.state.queue.length === 200);
    quiet([a, b]);
    a.send({ t: "queue.add", ...track(VIDEO_B, "One too many") });
    const full = await a.waitFor((m) => m.t === "error" && m.code === "queue_full");
    check("the 201st song is refused", !!full);

    quiet([a, b]);
    for (let i = 0; i < 80; i++) b.send({ t: "ping", c0: Date.now() });
    const limited = await b.waitFor((m) => m.t === "error" && m.code === "rate_limited", 2000).catch(() => null);
    check("a flood from one device is answered with rate_limited", !!limited);
    await sleep(1200);
    quiet([a, b]);
    b.send({ t: "ping", c0: Date.now() });
    check("and that device is served again a moment later", !!(await b.waitFor((m) => m.t === "pong", 1500).catch(() => null)));
    check("the other device was never held up", !!(await (async () => { a.send({ t: "ping", c0: Date.now() }); return a.waitFor((m) => m.t === "pong", 1500).catch(() => null); })()));
    [a, b].forEach((x) => x.close());
  }
}

/**
 * Behaviours that group listening elsewhere has settled, checked against this server:
 * Jellyfin SyncPlay's next/previous name the item they were pressed on and are ignored once the group moved on,
 * Syncplay's crossfire (seek, pause and play from several people at once), a seek during loading as in SharePlay's
 * coordinated seek, presence and ownership as in Spotify Jam. Ends with a randomized storm of commands from three
 * devices after which every device's own picture of the room must match the server's, from the messages alone.
 */
async function conformanceSection() {
  console.log("Market conformance");
  const track = (videoId, title) => ({ videoId, title, artist: "x", durMs: 200000 });
  const quiet = (clients) => clients.forEach((x) => (x.inbox.length = 0));
  const codeOf = (client) => client.ws.url.split("/room/")[1].split("?")[0];
  const views = async (clients) => {
    quiet(clients);
    clients.forEach((x) => x.send({ t: "resync" }));
    return all(clients, (x) => x.waitFor((m) => m.t === "state"));
  };
  /** A room of [names] playing [count] songs, everybody through the first barrier; returns the clients and the queue. */
  const playing = async (names, count) => {
    const clients = await freshRoom(names);
    clients[0].send({ t: "queue.addMany", tracks: Array.from({ length: count }, (_, i) => track([VIDEO_A, VIDEO_B, VIDEO_C][i % 3], `Song ${i}`)) });
    const st = await clients[0].waitFor((m) => m.t === "state" && m.state.queue.length === count);
    const p = await all(clients, (x) => x.waitFor((m) => m.t === "prepare"));
    clients.forEach((x) => x.send({ t: "ready", epoch: p[0].epoch }));
    await all(clients, (x) => x.waitFor((m) => m.t === "start"));
    quiet(clients);
    return { clients, ids: st.state.queue.map((q) => q.id) };
  };

  // Two people press next on the same song at the same moment: the room moves one song, not two
  {
    const { clients: [a, b, c], ids } = await playing(["Na", "Nb", "Nc"], 4);
    a.send({ t: "next", from: ids[0] });
    b.send({ t: "next", from: ids[0] });
    await sleep(400);
    let seen = await views([a, b, c]);
    check("two people pressing next on the same song move the room one song, not two", seen.every((m) => m.state.index === 1), JSON.stringify(seen.map((m) => m.state.index)));
    b.send({ t: "prev", from: ids[0] });
    await sleep(300);
    seen = await views([a, b, c]);
    check("a previous pressed on a song the room already left does nothing", seen.every((m) => m.state.index === 1));
    a.send({ t: "prev", from: ids[1] });
    await sleep(300);
    seen = await views([a, b, c]);
    check("a previous pressed on the current song works", seen.every((m) => m.state.index === 0));
    a.send({ t: "next" });
    await sleep(300);
    seen = await views([a, b, c]);
    check("a next from an older app that names no song still works", seen.every((m) => m.state.index === 1));
    [a, b, c].forEach((x) => x.close());
  }

  // Two people pause (or resume) at the same moment: one pause, one start, nobody flaps
  {
    const { clients: [a, b] } = await playing(["Da", "Db"], 1);
    a.send({ t: "pause" });
    b.send({ t: "pause" });
    await sleep(500);
    check("two pauses at once reach every device as one pause", a.inbox.filter((m) => m.t === "pause").length === 1 && b.inbox.filter((m) => m.t === "pause").length === 1);
    quiet([a, b]);
    a.send({ t: "play" });
    b.send({ t: "play" });
    await sleep(500);
    check("two plays at once reach every device as one start", a.inbox.filter((m) => m.t === "start").length === 1 && b.inbox.filter((m) => m.t === "start").length === 1);
    [a, b].forEach((x) => x.close());
  }

  // Somebody seeks while the song is still loading: the room starts at the new place, and a newcomer prepares there
  {
    const [a, b] = await freshRoom(["Sa2", "Sb2"]);
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    const p = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    b.send({ t: "seek", positionMs: 30000 });
    await sleep(300);
    const late = new Client(codeOf(a), "Sc2-id", "Sc2");
    await late.join();
    const lp = await late.waitFor((m) => m.t === "prepare");
    check("a seek while the song loads is kept for whoever joins meanwhile", lp.seekToMs === 30000, `seekToMs=${lp.seekToMs}`);
    [a, b, late].forEach((x) => x.send({ t: "ready", epoch: p[0].epoch }));
    const go = await all([a, b, late], (x) => x.waitFor((m) => m.t === "start", 3000)).catch(() => null);
    check("a seek while the song loads is where the room starts", !!go && go.every((st) => st.positionMs === 30000 && st.startAt === go[0].startAt), JSON.stringify(go?.map((st) => st.positionMs)));
    [a, b, late].forEach((x) => x.close());
  }

  // Everybody leaves while a song is loading: whoever comes back finds it paused, not starting by itself
  {
    const [a, b] = await freshRoom(["La3", "Lb3"]);
    const code = codeOf(a);
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    [a, b].forEach((x) => x.close());
    await sleep(400);
    const back = new Client(code, "La3-id", "La3");
    const st = await back.join(false);
    const again = await back.waitFor((m) => m.t === "prepare", 600).catch(() => null);
    if (again) back.send({ t: "ready", epoch: again.epoch });
    check("a room left while a song loads is paused when somebody comes back", st.state.phase === "paused", st.state.phase);
    check("and it does not start by itself", await back.stays((m) => m.t === "start", 800));
    back.close();
  }

  // Ownership cannot be taken by copying an id from the member list
  {
    const { code } = await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json();
    const owner = new Client(code, "Io-secret", "Io");
    await owner.join(true);
    owner.send({ t: "room.settings", guestControl: "add" });
    await owner.waitFor((m) => m.t === "state" && m.state.guestControl === "add");
    const guest = new Client(code, "Ig-secret", "Ig");
    const gs = await guest.join(false);
    const listed = gs.members.map((m) => m.id);
    check("the member list never shows a device's own secret id", !listed.includes("Io-secret") && !listed.includes("Ig-secret"), JSON.stringify(listed));
    const ownerEntry = gs.members.find((m) => m.owner);
    const impostor = new Client(code, ownerEntry.id, "Io");
    const is = await impostor.join(false);
    await sleep(300);
    check("joining with the owner's listed id does not make a device the owner", is.state.ownerId !== is.you && is.state.ownerId === ownerEntry.id);
    check("and does not push the real owner out", owner.ws.readyState === WebSocket.OPEN);
    quiet([impostor]);
    impostor.send({ t: "pause" });
    check("and that device stays a guest", !!(await impostor.waitFor((m) => m.t === "error" && m.code === "forbidden", 1500).catch(() => null)));
    [owner, guest, impostor].forEach((x) => x.close());
  }

  // An owner who leaves hands the room to somebody who is really there, not to a device that went quiet
  if (process.env.SIM_STALE_MS) {
    const staleMs = Number(process.env.SIM_STALE_MS);
    const { code } = await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json();
    const owner = new Client(code, "Ho-secret", "Ho");
    await owner.join(true);
    const quietOne = new Client(code, "Hq-secret", "Hq"); // here longest after the owner, then silent
    await quietOne.join(false);
    await sleep(50);
    const awake = new Client(code, "Ha-secret", "Ha");
    await awake.join(false);
    const keepAlive = setInterval(() => [owner, awake].forEach((x) => x.send({ t: "ping", c0: Date.now() })), 400);
    await sleep(staleMs + 800);
    clearInterval(keepAlive);
    quiet([awake]);
    owner.send({ t: "bye" });
    const handed = await awake.waitFor((m) => m.t === "state" && m.state.ownerId !== pid("Ho-secret"), 2000).catch(() => null);
    check("an owner who leaves hands the room to a member who is present, not to one gone quiet", handed?.state.ownerId === pid("Ha-secret"), handed?.state.ownerId);
    [owner, quietOne, awake].forEach((x) => x.close());
  }

  // Devices that say their round trip get a start scheduled sooner than the old fixed 1.5 s; one that does not keeps it
  {
    const [a, b] = await freshRoom(["Ra5", "Rb5"]);
    [a, b].forEach((x) => x.send({ t: "ping", c0: Date.now(), rtt: 40 }));
    await all([a, b], (x) => x.waitFor((m) => m.t === "pong"));
    a.send({ t: "queue.addMany", tracks: [track(VIDEO_A, "One")] });
    const p = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
    [a, b].forEach((x) => x.send({ t: "ready", epoch: p[0].epoch }));
    const st = await a.waitFor((m) => m.t === "start");
    const lead = st.startAt - st._at;
    check("devices on a good network are started about 0.6 s ahead, not 1.5 s", lead > 300 && lead < 900, `lead=${lead}ms`);
    const old = new Client(codeOf(a), "Rc5-id", "Rc5"); // an older app: says nothing about its round trip
    await old.join();
    quiet([a, b, old]);
    a.send({ t: "seek", positionMs: 10000 });
    const st2 = await a.waitFor((m) => m.t === "start");
    const lead2 = st2.startAt - st2._at;
    check("with an older app in the room the lead is the full 1.5 s", lead2 > 1100 && lead2 < 1700, `lead=${lead2}ms`);
    [a, b, old].forEach((x) => x.close());
  }

  // The clock the devices sync to answers within the round trip, and never goes back
  {
    const [a] = await freshRoom(["Ck"]);
    const samples = [];
    for (let i = 0; i < 10; i++) {
      const c0 = Date.now();
      a.send({ t: "ping", c0 });
      const pong = await a.waitFor((m) => m.t === "pong" && m.c0 === c0);
      samples.push({ c0, s1: pong.s1, c2: pong._at });
      await sleep(30);
    }
    // Server and simulation share this machine's clock here, so s1 must lie between sending and receiving
    check("every pong is stamped between its ping and its answer", samples.every((x) => x.s1 >= x.c0 && x.s1 <= x.c2), JSON.stringify(samples.slice(0, 3)));
    check("and the server clock never goes back", samples.every((x, i) => i === 0 || x.s1 >= samples[i - 1].s1));
    a.close();
  }

  // A storm of commands from three devices at once, three times with different seeds
  for (const seed of [Number(process.env.SIM_SEED) || 0x5a9, 0x1234, 0xbeef].map((s, i) => s + i)) {
    await stormRound(seed);
  }
}

/** A small seeded random source, so that a failing storm can be replayed with SIM_SEED. */
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Three devices send random commands with small random gaps and answer every prepare after a random delay, like
 * phones loading at their own pace. Afterwards: every device saw epochs only grow, every device got the same start for
 * an epoch, the room is not stuck loading, and what each device pieced together from the messages it received is
 * exactly the server's state.
 */
async function stormRound(seed) {
  const rand = mulberry32(seed);
  // Loading delays draw from their own source, so that the commands stay the same however the answers interleave
  const loading = mulberry32(seed ^ 0x9e3779b9);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const clients = await freshRoom([`F${seed}a`, `F${seed}b`, `F${seed}c`]);
  /** Follows what [client] is told, the way a phone pieces the room together. */
  const follow = (client) => {
    const model = { epoch: -1, phase: "idle", index: 0, positionMs: 0, startedAt: 0, queue: [], backwards: [], starts: new Map(), errors: [] };
    const inner = client.ws.onmessage;
    client.ws.onmessage = (event) => {
      inner(event);
      const m = JSON.parse(event.data);
      const epoch = m.t === "state" ? m.state.epoch : m.epoch;
      if (typeof epoch === "number") {
        if (epoch < model.epoch) model.backwards.push(`${m.t} ${epoch} after ${model.epoch}`);
      }
      switch (m.t) {
        case "state":
          Object.assign(model, { epoch: m.state.epoch, phase: m.state.phase, index: m.state.index, positionMs: m.state.positionMs, startedAt: m.state.startedAt, queue: m.state.queue.map((q) => q.id) });
          break;
        case "prepare":
          Object.assign(model, { epoch: m.epoch, phase: "preparing", index: m.index, positionMs: m.seekToMs });
          setTimeout(() => client.ws.readyState === WebSocket.OPEN && client.send({ t: "ready", epoch: m.epoch }), Math.floor(loading() * 150));
          break;
        case "start":
          Object.assign(model, { epoch: m.epoch, phase: "playing", positionMs: m.positionMs, startedAt: m.startAt - m.positionMs });
          model.starts.set(m.epoch, `${m.startAt}/${m.positionMs}`);
          break;
        case "pause":
          Object.assign(model, { epoch: m.epoch, phase: "paused", positionMs: m.positionMs });
          break;
        case "advance":
          Object.assign(model, { epoch: m.epoch, phase: "playing", index: m.index, positionMs: 0, startedAt: m.startedAt });
          break;
        case "error":
          model.errors.push(m.code);
          break;
      }
    };
    return model;
  };
  const models = clients.map(follow);

  const songs = [VIDEO_A, VIDEO_B, VIDEO_C];
  clients[0].send({ t: "queue.addMany", tracks: Array.from({ length: 6 }, (_, i) => ({ videoId: songs[i % 3], title: `S${i}`, artist: "x", durMs: 200000 })) });
  await sleep(600);

  const code = clients[0].ws.url.split("/room/")[1].split("?")[0];
  const dropAt = 10 + Math.floor(rand() * 25);
  for (let i = 0; i < 45; i++) {
    if (i === dropAt) {
      // One device loses its connection in the middle of it all and comes back on a new one, as phones do
      const k = Math.floor(rand() * clients.length);
      const gone = clients[k];
      gone.close();
      const back = new Client(code, gone.clientId, gone.name);
      models[k] = follow(back);
      clients[k] = back;
      await back.join();
    }
    const at = Math.floor(rand() * clients.length);
    const client = clients[at];
    const { queue, index } = models[at];
    const current = queue[index];
    const any = queue.length ? pick(queue) : undefined;
    const r = rand();
    let msg;
    if (r < 0.14) msg = { t: "play" };
    else if (r < 0.28) msg = { t: "pause" };
    else if (r < 0.4) msg = { t: "seek", positionMs: Math.floor(rand() * 190000) };
    else if (r < 0.54) msg = { t: "next", from: current };
    else if (r < 0.62) msg = { t: "prev", from: current };
    else if (r < 0.72 && any) msg = { t: "jump", id: any };
    else if (r < 0.82) msg = { t: "queue.add", videoId: pick(songs), title: `Added ${i}`, artist: "x", durMs: 200000, next: rand() < 0.5 };
    else if (r < 0.88 && any && queue.length > 3) msg = { t: "queue.remove", id: any };
    else if (r < 0.96 && any) msg = { t: "queue.move", id: any, toIndex: Math.floor(rand() * queue.length) };
    else msg = { t: "queue.shuffle" };
    client.send(msg);
    await sleep(15 + Math.floor(rand() * 45));
  }
  // Let every barrier release: devices answer within 150 ms, nothing else is sent
  await sleep(1500);

  const pictured = models.map((m) => ({ ...m, queue: [...m.queue] }));
  clients.forEach((x) => (x.inbox.length = 0));
  clients.forEach((x) => x.send({ t: "resync" }));
  const truth = await all(clients, (x) => x.waitFor((m) => m.t === "state"));
  const s = truth[0].state;
  const label = `(seed ${seed})`;
  check(`storm ${label}: no device ever saw the room go back to an older epoch`, models.every((m) => m.backwards.length === 0), JSON.stringify(models.map((m) => m.backwards.slice(0, 2))));
  const startsAgree = [...new Set(models.flatMap((m) => [...m.starts.keys()]))].every((epoch) => {
    const told = models.map((m) => m.starts.get(epoch)).filter(Boolean);
    return told.every((x) => x === told[0]);
  });
  check(`storm ${label}: every device was given the same start for each epoch`, startsAgree);
  check(`storm ${label}: the room is not left loading once every device is ready`, s.phase !== "preparing", s.phase);
  check(`storm ${label}: the current song is in the queue`, s.queue.length === 0 ? s.index === 0 : s.index >= 0 && s.index < s.queue.length, `${s.index}/${s.queue.length}`);
  const same = (m) =>
    m.epoch === s.epoch && m.phase === s.phase && m.index === s.index && m.queue.join() === s.queue.map((q) => q.id).join() &&
    (s.phase !== "paused" || m.positionMs === s.positionMs) && (s.phase !== "playing" || m.startedAt === s.startedAt);
  check(`storm ${label}: what each device pieced together from the messages is the server's state`, pictured.every(same),
    JSON.stringify({ server: [s.epoch, s.phase, s.index, s.positionMs, s.startedAt], devices: pictured.map((m) => [m.epoch, m.phase, m.index, m.positionMs, m.startedAt]) }));
  check(`storm ${label}: no device was refused or slowed down`, models.every((m) => m.errors.length === 0), JSON.stringify(models.map((m) => m.errors)));
  clients.forEach((x) => x.close());
}

main().catch((error) => {
  console.error("Simulation crashed:", error);
  process.exit(2);
});
