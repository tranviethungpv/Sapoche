// End-to-end simulation of the room protocol against a running server (`npm run dev`).
// Usage: node scripts/sim.mjs [baseUrl]   (default http://127.0.0.1:8787)
// When the server has a ROOM_KEY, pass it in UNISON_KEY (npm run sim:keyed does this against a local server).

const BASE = process.argv[2] ?? "http://127.0.0.1:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const KEY = process.env.UNISON_KEY ?? "";
const keyQuery = KEY ? `?key=${encodeURIComponent(KEY)}` : "";
const keyHeaders = KEY ? { "X-Unison-Key": KEY } : {};

let passed = 0;
let failed = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
  }

  async join() {
    await this.opened;
    this.send({ t: "join", clientId: this.clientId, name: this.name });
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
      const timer = setTimeout(() => reject(new Error(`${this.name}: timeout waiting for message`)), timeoutMs);
      this.waiters.push((msg) => {
        if (!predicate(msg)) return false;
        clearTimeout(timer);
        this.inbox.splice(this.inbox.indexOf(msg), 1);
        resolve(msg);
        return true;
      });
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
  check("join returns state with idle phase", sa.state.phase === "idle" && sa.you === "dev-a");

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
  check("existing members are told about the new member", members.members.some((m) => m.id === "dev-d"));

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
  await unplayableSection();
  await playlistAndRepeatSection();
  await soloAndPresenceSection(Number(process.env.SIM_STALE_MS) || 0);
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
  const wrongKey = await fetch(`${BASE}/rooms`, { method: "POST", headers: { "X-Unison-Key": "wrong" } });
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

  check("members start out present and following", member(await a.waitFor((m) => m.t === "members" && m.members.length === 3), "Xc-id").solo === false);

  c.send({ t: "solo", on: true });
  const soloMsg = await a.waitFor((m) => m.t === "members" && member(m, "Xc-id")?.solo === true);
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
  check("a pause says who paused", paused.by === "Xb-id", `by=${paused.by}`);
  b.send({ t: "play" });
  const resumed = await a.waitFor((m) => m.t === "start");
  check("a resume says who resumed", resumed.by === "Xb-id");

  a.send({ t: "queue.add", videoId: VIDEO_B, title: "Two", artist: "x", durMs: 200000 });
  await a.waitFor((m) => m.t === "state" && m.state.queue.length === 2);
  a.send({ t: "next" });
  const skipped = await all([a, b], (x) => x.waitFor((m) => m.t === "prepare"));
  check("a skip says who skipped", skipped[0].by === "Xa-id");

  // c missed nothing on purpose here, but asks again as it would when rejoining
  c.inbox.length = 0; // whatever it heard so far must not be mistaken for the answer
  c.send({ t: "resync" });
  const state = await c.waitFor((m) => m.t === "state");
  check("resync returns the room's state", state.state.queue.length === 2 && state.state.index === 1);
  const again = await c.waitFor((m) => m.t === "prepare", 1500);
  check("resync during a barrier also returns the prepare", again.item.videoId === VIDEO_B && again.epoch === skipped[0].epoch);

  c.send({ t: "solo", on: false });
  check("the device is following again", !!(await a.waitFor((m) => m.t === "members" && member(m, "Xc-id")?.solo === false)));

  if (staleMs > 0) {
    await sleep(staleMs + 400);
    const away = await a.waitFor((m) => m.t === "members" && member(m, "Xc-id")?.away === true, 3000);
    check("a device that went quiet is marked away", !!away);
    c.send({ t: "ping", c0: Date.now() });
    const back = await a.waitFor((m) => m.t === "members" && member(m, "Xc-id")?.away === false, 3000);
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

main().catch((error) => {
  console.error("Simulation crashed:", error);
  process.exit(2);
});
