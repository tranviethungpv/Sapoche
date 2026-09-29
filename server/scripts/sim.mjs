// End-to-end simulation of the room protocol against a running server (`npm run dev`).
// Usage: node scripts/sim.mjs [baseUrl]   (default http://127.0.0.1:8787)

const BASE = process.argv[2] ?? "http://127.0.0.1:8787";
const WS_BASE = BASE.replace(/^http/, "ws");

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
    this.ws = new WebSocket(`${WS_BASE}/room/${code}`);
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
  check("GET /health is ok", health.ok);
  const created = await (await fetch(`${BASE}/rooms`, { method: "POST" })).json();
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

  [a, b, d].forEach((x) => x.close());
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}


/** Gapless advance: devices that already moved on by themselves fix the next start time. */
async function gaplessSection() {
  console.log("Gapless advance");
  const { code } = await (await fetch(`${BASE}/rooms`, { method: "POST" })).json();
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
  const room2 = await (await fetch(`${BASE}/rooms`, { method: "POST" })).json();
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

main().catch((error) => {
  console.error("Simulation crashed:", error);
  process.exit(2);
});
