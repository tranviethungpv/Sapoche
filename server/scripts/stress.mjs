// Stress tests for the room server: hostile input, many busy rooms at once, and devices that keep coming and going.
// Usage: SAPOCHE_KEY=... node scripts/stress.mjs [baseUrl]   (npm run stress starts a local server and runs this)
// Every part ends by checking that the rooms still hold together: the state is sane, every device agrees with it,
// and the room still answers.

const BASE = process.argv[2] ?? "http://127.0.0.1:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const KEY = process.env.SAPOCHE_KEY ?? "";
const keyQuery = KEY ? `?key=${encodeURIComponent(KEY)}` : "";
const keyHeaders = KEY ? { "X-Sapoche-Key": KEY } : {};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const VIDEOS = ["bNp9pn0ni3I", "UoXllQoqEBY", "cnHHCR7EW10"];
const PHASES = new Set(["idle", "preparing", "playing", "paused"]);

let passed = 0;
let failed = 0;
function check(name, condition, detail = "") {
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} ${detail}`);
  }
}

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

/** A device that answers every prepare (after [readyDelay] ms) and keeps the last state and every error it was sent. */
class Device {
  constructor(code, clientId, name, readyDelay = () => 0) {
    this.clientId = clientId;
    this.name = name;
    this.inbox = [];
    this.errors = [];
    this.waiters = [];
    this.closedWith = null;
    this.ws = new WebSocket(`${WS_BASE}/room/${code}${keyQuery}`);
    this.opened = new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
    this.closed = new Promise((resolve) => {
      this.ws.onclose = (e) => {
        this.closedWith = e.code;
        resolve(e.code);
      };
    });
    this.ws.onmessage = (event) => {
      const m = JSON.parse(event.data);
      m._at = Date.now();
      if (m.t === "error") this.errors.push(m.code);
      if (m.t === "state") this.state = m;
      if (m.t === "prepare") {
        setTimeout(() => this.open && this.send({ t: "ready", epoch: m.epoch }), readyDelay());
      }
      this.inbox.push(m);
      if (this.inbox.length > 500) this.inbox.splice(0, 250);
      this.waiters = this.waiters.filter((w) => !w(m));
    };
  }

  get open() {
    return this.ws.readyState === WebSocket.OPEN;
  }

  send(msg) {
    if (this.open) this.ws.send(typeof msg === "string" ? msg : JSON.stringify(msg));
  }

  async join(create) {
    await this.opened;
    this.send({ t: "join", clientId: this.clientId, name: this.name, ...(create === undefined ? {} : { create }) });
    return this.waitFor((m) => m.t === "state", 5000);
  }

  waitFor(predicate, timeoutMs = 3000) {
    return new Promise((resolve, reject) => {
      const waiter = (m) => {
        if (!predicate(m)) return false;
        clearTimeout(timer);
        resolve(m);
        return true;
      };
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(new Error(`${this.name}: timeout`));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  /** The room as the server has it now. */
  async truth() {
    this.send({ t: "resync" });
    return (await this.waitFor((m) => m.t === "state", 5000)).state;
  }

  async alive() {
    const c0 = Date.now() + Math.random();
    this.send({ t: "ping", c0 });
    try {
      await this.waitFor((m) => m.t === "pong" && m.c0 === c0, 3000);
      return true;
    } catch {
      return false;
    }
  }

  close() {
    try {
      this.ws.close();
    } catch {
      // already closing
    }
  }
}

async function newCode() {
  return (await (await fetch(`${BASE}/rooms`, { method: "POST", headers: keyHeaders })).json()).code;
}

/** What must hold for any room state, whatever was sent to it. */
function sane(s) {
  const problems = [];
  if (!PHASES.has(s.phase)) problems.push(`phase ${s.phase}`);
  if (!Number.isInteger(s.index) || s.index < 0 || (s.queue.length > 0 && s.index >= s.queue.length) || (s.queue.length === 0 && s.index !== 0)) problems.push(`index ${s.index}/${s.queue.length}`);
  if (s.queue.length === 0 && s.phase !== "idle") problems.push(`empty queue in ${s.phase}`);
  if (s.queue.length > 200) problems.push(`queue ${s.queue.length}`);
  if (!Number.isFinite(s.positionMs) || s.positionMs < 0) problems.push(`positionMs ${s.positionMs}`);
  if (!Number.isFinite(s.startedAt)) problems.push(`startedAt ${s.startedAt}`);
  if (!Number.isInteger(s.epoch) || s.epoch < 0) problems.push(`epoch ${s.epoch}`);
  if (!["off", "all", "one"].includes(s.repeat)) problems.push(`repeat ${s.repeat}`);
  if (!["all", "add"].includes(s.guestControl)) problems.push(`guestControl ${s.guestControl}`);
  if (s.name !== undefined && (typeof s.name !== "string" || s.name.length > 32)) problems.push(`name`);
  const ids = new Set();
  for (const q of s.queue) {
    if (!/^[A-Za-z0-9_-]{11}$/.test(q.videoId)) problems.push(`videoId ${q.videoId}`);
    if (typeof q.title !== "string" || q.title.length > 200 || typeof q.artist !== "string" || q.artist.length > 100) problems.push("text");
    if (!Number.isFinite(q.durMs) || q.durMs < 0) problems.push(`durMs ${q.durMs}`);
    if (ids.has(q.id)) problems.push(`duplicate id ${q.id}`);
    ids.add(q.id);
  }
  return problems;
}

// ---------------------------------------------------------------- hostile input

/** Every value of the wrong kind we can think of. */
const NASTY = [null, true, false, 0, -1, 1e308, -1e308, 2 ** 53 + 1, 0.5, "", " ", "x".repeat(5000), "../../etc", "<script>", "\u0000", "💥".repeat(100), [], [1, 2], {}, { a: 1 }, "NaN", "Infinity", "-0", "11characters", "bNp9pn0ni3I", "q1"];

const TYPES = [
  "join", "bye", "kick", "room.name", "room.settings", "ping", "avatar.set", "avatar.get", "queue.add", "queue.addMany", "queue.remove",
  "queue.swap", "queue.clear", "queue.shuffle", "jump", "queue.move", "play", "pause", "seek", "next", "prev", "repeat", "autoplay",
  "solo", "resync", "ready", "resolveFailed", "ended", "advanced", "report", "nope", "", "__proto__", "constructor", "toString",
];
const FIELDS = ["clientId", "name", "create", "id", "guestControl", "c0", "rtt", "data", "videoId", "title", "artist", "thumb", "durMs", "next", "tracks", "track", "toIndex", "positionMs", "from", "mode", "on", "epoch", "reason", "itemId", "startedAt", "posMs", "bufferMs"];

async function hostileSection() {
  console.log("Hostile input");
  const code = await newCode();
  const owner = new Device(code, "hostile-owner", "Owner");
  await owner.join(true);
  owner.send({ t: "queue.addMany", tracks: VIDEOS.map((v, i) => ({ videoId: v, title: `S${i}`, artist: "a", durMs: 200000 })) });
  await sleep(500);
  const attacker = new Device(code, "hostile-attacker", "Attacker");
  await attacker.join(false);

  const rand = mulberry32(0xbad);
  const pick = (list) => list[Math.floor(rand() * list.length)];
  let sent = 0;
  // Raw garbage first: not JSON, JSON that is not an object, binary frames, oversized text
  for (const raw of ["", "{", "null", "[]", "42", '"t"', '{"t":5}', '{"t":null}', '{"t":{}}', "\u0000\u0001", "{".repeat(10000), "x".repeat(40000)]) {
    attacker.send(raw);
    sent++;
    await sleep(60);
  }
  attacker.ws.send(new Uint8Array([1, 2, 3, 255]));
  sent++;
  await sleep(100);
  // Then every type with random fields of the wrong kind, slowly enough to stay under the rate limit
  for (let i = 0; i < 700; i++) {
    const msg = { t: pick(TYPES) };
    const count = Math.floor(rand() * 4);
    for (let k = 0; k < count; k++) msg[pick(FIELDS)] = pick(NASTY);
    if (msg.t === "join" || msg.t === "bye" || msg.t === "kick") continue; // these end or replace the connection; tested below
    if (rand() < 0.1) msg.tracks = Array.from({ length: 150 }, () => ({ videoId: pick(NASTY), title: pick(NASTY), durMs: pick(NASTY) }));
    attacker.send(msg);
    sent++;
    if (i % 15 === 14) await sleep(800);
  }
  await sleep(1500);
  check(`after ${sent} hostile messages the attacker's connection is still served`, await attacker.alive());
  check("and so is everybody else's", await owner.alive());
  const s = await owner.truth();
  const problems = sane(s);
  check("the room's state is still sane", problems.length === 0, problems.join(", "));
  const unexpected = attacker.errors.filter((c) => !["bad_json", "bad_message", "unknown_type", "bad_video", "rate_limited", "queue_full", "not_joined", "forbidden"].includes(c));
  check("only the documented error codes came back", unexpected.length === 0, JSON.stringify([...new Set(unexpected)]));

  // Joins with hostile identities never take over or crash the room
  for (const value of NASTY) {
    const d = new Device(code, "x", "x");
    await d.opened;
    d.send({ t: "join", clientId: value, name: value, create: value });
    await Promise.race([d.waitFor((m) => m.t === "state" || m.t === "error", 1500).catch(() => null), d.closed]);
    d.close();
  }
  await sleep(300);
  const after = await owner.truth();
  check("joins with every kind of bad identity leave the owner in charge", after.ownerId === s.ownerId);
  check("and the room sane", sane(after).length === 0, sane(after).join(", "));
  // A kick or bye with nonsense in it does nothing to anybody else
  attacker.send({ t: "kick", id: null });
  attacker.send({ t: "kick", id: ["x"] });
  await sleep(200);
  check("a guest's kick of nonsense hurts nobody", owner.open && (await owner.alive()));
  owner.close();
  attacker.close();
}

// ---------------------------------------------------------------- many busy rooms

async function busyRoom(roomNo, devices, seconds, seed) {
  const rand = mulberry32(seed);
  const code = await newCode();
  const clients = [];
  for (let i = 0; i < devices; i++) {
    const d = new Device(code, `busy-${roomNo}-${i}`, `B${i}`, () => Math.floor(rand() * 400));
    await d.join(i === 0);
    clients.push(d);
  }
  clients[0].send({ t: "queue.addMany", tracks: Array.from({ length: 20 }, (_, i) => ({ videoId: VIDEOS[i % 3], title: `S${i}`, artist: "a", durMs: 600000 + i * 1000 })) }); // long songs: no end of song in the middle of the checks
  await sleep(300);
  const until = Date.now() + seconds * 1000;
  let sent = 0;
  while (Date.now() < until) {
    const d = clients[Math.floor(rand() * clients.length)];
    const st = d.state?.state;
    const current = st?.queue[st.index]?.id;
    const any = st?.queue.length ? st.queue[Math.floor(rand() * st.queue.length)].id : undefined;
    const r = rand();
    if (r < 0.15) d.send({ t: "play" });
    else if (r < 0.3) d.send({ t: "pause" });
    else if (r < 0.42) d.send({ t: "seek", positionMs: Math.floor(rand() * 30000) });
    else if (r < 0.55) d.send({ t: "next", from: current });
    else if (r < 0.6) d.send({ t: "prev", from: current });
    else if (r < 0.7 && any) d.send({ t: "jump", id: any });
    else if (r < 0.8) d.send({ t: "queue.add", videoId: VIDEOS[Math.floor(rand() * 3)], title: "add", artist: "a", durMs: 600000, next: rand() < 0.5 });
    else if (r < 0.85 && any) d.send({ t: "queue.remove", id: any });
    else if (r < 0.9 && any) d.send({ t: "queue.move", id: any, toIndex: Math.floor(rand() * 20) });
    else if (r < 0.93) d.send({ t: "solo", on: rand() < 0.5 });
    else if (r < 0.96) d.send({ t: "repeat", mode: ["off", "all", "one"][Math.floor(rand() * 3)] });
    else d.send({ t: "ping", c0: Date.now(), rtt: Math.floor(rand() * 300) });
    sent++;
    await sleep(40 + Math.floor(rand() * 80));
  }
  // Everybody follows the room again. A song still loading must start within the barrier's 8 s whatever happens
  clients.forEach((d) => d.send({ t: "solo", on: false }));
  const settleFrom = Date.now();
  let first = await clients[0].truth();
  while (first.phase === "preparing" && Date.now() - settleFrom < 9500) {
    await sleep(250);
    first = await clients[0].truth();
  }
  const settledMs = Date.now() - settleFrom;
  // A saturated local server may still be working through the last commands: wait until the room stops changing
  for (let still = 0, last = first.epoch; still < 3 && Date.now() - settleFrom < 30_000; ) {
    await sleep(500);
    const now = (await clients[0].truth()).epoch;
    still = now === last ? still + 1 : 0;
    last = now;
  }
  // Then every device, asked one after the other with nothing else going on, is told the same
  const truths = [];
  for (const d of clients) truths.push(await d.truth());
  const problems = sane(truths[0]);
  const agree = truths.every((t) => t.epoch === truths[0].epoch && t.index === truths[0].index && t.phase === truths[0].phase && t.queue.length === truths[0].queue.length);
  if (!agree) console.log(`  room ${roomNo} told apart:`, JSON.stringify(truths.map((t) => [t.epoch, t.index, t.phase, t.queue.length])));
  const rtts = [];
  for (const d of clients) {
    const t0 = Date.now();
    if (await d.alive()) rtts.push(Date.now() - t0);
  }
  const refused = clients.flatMap((d) => d.errors).filter((c) => c !== "queue_full");
  clients.forEach((d) => d.close());
  return { roomNo, sent, problems, agree, stuck: first.phase === "preparing", settledMs, rtts, refused, answered: rtts.length === clients.length };
}

async function loadSection() {
  const rooms = Number(process.env.STRESS_ROOMS) || 24;
  const devices = Number(process.env.STRESS_DEVICES) || 6;
  const seconds = Number(process.env.STRESS_SECONDS) || 20;
  console.log(`Load: ${rooms} rooms x ${devices} devices, ${seconds} s of commands each, all at once`);
  const watcher = new Device(await newCode(), "watcher", "Watcher");
  await watcher.join(true);
  const during = [];
  let watching = true;
  const watch = (async () => {
    while (watching) {
      const t0 = Date.now();
      if (await watcher.alive()) during.push(Date.now() - t0);
      await sleep(250);
    }
  })();
  const results = await Promise.all(Array.from({ length: rooms }, (_, i) => busyRoom(i, devices, seconds, 1000 + i)));
  watching = false;
  await watch;
  watcher.close();
  during.sort((a, b) => a - b);
  const settled = results.map((r) => r.settledMs).sort((a, b) => a - b);
  console.log(`  an idle room's ping during the load: p50=${during[Math.floor(during.length / 2)]}ms p99=${during[Math.floor(during.length * 0.99)]}ms; loading settled after the storm in at most ${settled.at(-1)}ms`);
  const total = results.reduce((n, r) => n + r.sent, 0);
  const rtts = results.flatMap((r) => r.rtts).sort((a, b) => a - b);
  const p = (q) => rtts[Math.min(rtts.length - 1, Math.floor(rtts.length * q))];
  console.log(`  ${total} commands sent; ping after the storm p50=${p(0.5)}ms p99=${p(0.99)}ms max=${rtts.at(-1)}ms`);
  check("every room's state is sane", results.every((r) => r.problems.length === 0), JSON.stringify(results.filter((r) => r.problems.length).map((r) => [r.roomNo, r.problems])));
  check("in every room every device is told the same state", results.every((r) => r.agree));
  check("no room stays loading past the barrier's 8 s", results.every((r) => !r.stuck), JSON.stringify(results.filter((r) => r.stuck).map((r) => r.roomNo)));
  check("every device still answers", results.every((r) => r.answered));
  check("nobody was refused or rate limited at a person's pace", results.every((r) => r.refused.length === 0), JSON.stringify(results.flatMap((r) => r.refused).slice(0, 10)));
  // One local workerd runs every room in one process here, unlike Cloudflare where each room is its own object, so
  // this only asks that nothing is starved; the numbers above say how busy it got
  check("no device waited more than 5 s for an answer, even with the local server saturated", p(0.99) < 5000 && during.at(-1) < 5000, `p99=${p(0.99)}ms, idle room max=${during.at(-1)}ms`);
}

// ---------------------------------------------------------------- coming and going

async function churnSection() {
  const rounds = Number(process.env.STRESS_CHURN) || 150;
  console.log(`Churn: ${rounds} connections come and go while two devices listen`);
  const code = await newCode();
  const a = new Device(code, "churn-a", "A");
  await a.join(true);
  const b = new Device(code, "churn-b", "B");
  await b.join(false);
  a.send({ t: "queue.addMany", tracks: VIDEOS.map((v, i) => ({ videoId: v, title: `S${i}`, artist: "a", durMs: 200000 })) });
  await a.waitFor((m) => m.t === "start", 5000);
  // The two who stay ping every 20 s, as the app does every 30 s; a device that says nothing for 150 s is taken for dead
  const keepAlive = setInterval(() => [a, b].forEach((d) => d.send({ t: "ping", c0: Date.now() })), 20_000);
  const rand = mulberry32(77);
  const live = [];
  for (let i = 0; i < rounds; i++) {
    const id = `churn-${Math.floor(rand() * 20)}`; // the same devices come back again and again
    const d = new Device(code, id, id, () => Math.floor(rand() * 200));
    const joined = await d.join(false).catch(() => null);
    if (joined) live.push(d);
    if (rand() < 0.3 && live.length) live.splice(Math.floor(rand() * live.length), 1)[0].send({ t: "bye" });
    if (rand() < 0.3 && live.length) live.splice(Math.floor(rand() * live.length), 1)[0].close(); // drops without a word
    if (rand() < 0.2) a.send({ t: "next", from: a.state?.state.queue[a.state.state.index]?.id });
  }
  await sleep(1500);
  const s = await a.truth();
  const members = a.state.members.map((m) => m.id);
  const expected = new Set([a.state.you, ...live.filter((d) => d.open).map((d) => d.state?.you)]);
  for (const d of live) if (d.open) expected.add(d.state.you);
  const unique = new Set(members);
  check("the room is sane after all that", sane(s).length === 0, sane(s).join(", "));
  check("nobody is listed twice", unique.size === members.length, JSON.stringify(members));
  check("at most twelve are listed", members.length <= 12, `${members.length}`);
  const aAlive = await a.alive();
  const bAlive = await b.alive();
  check("the two who stayed are still served", aAlive && bAlive, JSON.stringify({ aAlive, bAlive, aClosed: a.closedWith, bClosed: b.closedWith, aErrors: a.errors, bErrors: b.errors }));
  check("the owner who never left is still the owner", s.ownerId === a.state.you);
  clearInterval(keepAlive);
  live.forEach((d) => d.close());
  a.close();
  b.close();
}

async function main() {
  const only = process.env.STRESS_ONLY;
  if (!only || only === "hostile") await hostileSection();
  if (!only || only === "load") await loadSection();
  if (!only || only === "churn") await churnSection();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("Stress run crashed:", error);
  process.exit(2);
});
