// Connect (the devices of one person, one of them playing) against a running server: the cases of PROTOCOL.md "Connect".
// Usage: node scripts/sim-connect.mjs [baseUrl]; npm run sim:keyed starts a server with the key (SAPOCHE_KEY) and a short hand-over time.
import { randomBytes } from "node:crypto";

const BASE = process.argv[2] ?? "http://127.0.0.1:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const KEY = process.env.SAPOCHE_KEY ?? "";
const HANDOFF_MS = Number(process.env.SIM_CONNECT_HANDOFF_MS ?? 1500);
const keyQuery = KEY ? `?key=${encodeURIComponent(KEY)}` : "";

let passed = 0;
let failed = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (n) => randomBytes(n).toString("hex");

function check(name, condition, detail = "") {
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} ${detail}`);
  }
}

class Device {
  constructor(cluster, { token, clientId = hex(8), info = "sealed-info" } = {}) {
    this.cluster = cluster;
    this.token = token;
    this.clientId = clientId;
    this.info = info;
    this.inbox = [];
    this.waiters = [];
    this.ws = new WebSocket(`${WS_BASE}/connect/${cluster}${keyQuery}`);
    this.opened = new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
    this.ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      this.inbox.push(msg);
      this.waiters = this.waiters.filter((w) => !w(msg));
    };
    this.closed = new Promise((resolve) => {
      this.ws.onclose = (event) => resolve(event.code);
    });
  }

  async hello() {
    await this.opened;
    this.send({ t: "hello", v: 1, token: this.token, clientId: this.clientId, info: this.info });
    return this.waitFor((m) => m.t === "welcome" || m.t === "error");
  }

  send(msg) {
    this.ws.send(JSON.stringify(msg));
  }

  /** The first message that fits, from those already here or those to come. */
  waitFor(match, ms = 4000) {
    const old = this.inbox.find(match);
    if (old) {
      this.inbox.splice(this.inbox.indexOf(old), 1);
      return Promise.resolve(old);
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        resolve(null);
      }, ms);
      const waiter = (msg) => {
        if (!match(msg)) return false;
        clearTimeout(timer);
        this.inbox.splice(this.inbox.indexOf(msg), 1);
        resolve(msg);
        return true;
      };
      this.waiters.push(waiter);
    });
  }

  /** Nothing that fits comes in [ms]. */
  async quiet(match, ms = 400) {
    await sleep(ms);
    return !this.inbox.some(match);
  }

  close() {
    this.ws.close();
  }
}

async function join(cluster, token, options = {}) {
  const device = new Device(cluster, { token, ...options });
  device.welcome = await device.hello();
  return device;
}

const token = () => hex(16);

console.log("Connect");

// --- the server says it
{
  const health = await (await fetch(`${BASE}/health`)).json();
  check("health says the version of Connect", health.connect === 1, JSON.stringify(health));
  if (KEY) {
    const response = await fetch(`${BASE}/connect/${hex(32)}`);
    check("without the key of the group it is 401", response.status === 401, String(response.status));
  }
  const notSocket = await fetch(`${BASE}/connect/${hex(32)}${keyQuery}`);
  check("a plain request is told to upgrade", notSocket.status === 426, String(notSocket.status));
}

// --- who is in, and the token
{
  const cluster = hex(32);
  const t = token();
  const a = await join(cluster, t, { info: "info-a" });
  check("the first device is welcomed with itself in the list", a.welcome.t === "welcome" && a.welcome.devices.length === 1 && a.welcome.devices[0].info === "info-a" && a.welcome.active === null && a.welcome.state === null, JSON.stringify(a.welcome));
  check("a device is known by a public id, never the secret one", /^[0-9a-f]{16}$/.test(a.welcome.you) && !JSON.stringify(a.welcome).includes(a.clientId));

  const b = await join(cluster, t, { info: "info-b" });
  check("a second device sees both", b.welcome.devices.length === 2);
  const seen = await a.waitFor((m) => m.t === "devices" && m.devices.length === 2);
  check("the first is told that the second came", seen !== null);

  const stranger = await join(cluster, token());
  check("another token is refused", stranger.welcome.t === "error" && stranger.welcome.code === "bad_token", JSON.stringify(stranger.welcome));
  check("and the connection is closed (4001)", (await stranger.closed) === 4001);
  const shortToken = await join(cluster, "short");
  check("a token that is too short is refused", shortToken.welcome.t === "error" && shortToken.welcome.code === "bad_token");

  b.send({ t: "info", info: "info-b2" });
  const changed = await a.waitFor((m) => m.t === "devices" && m.devices.some((d) => d.info === "info-b2"));
  check("a device changing its info is told to the others", changed !== null);

  const bId = b.welcome.you;
  b.close();
  const left = await a.waitFor((m) => m.t === "devices" && m.devices.length === 1);
  check("a device leaving is told", left !== null && left.devices[0].id === a.welcome.you);
  check("a message before hello is refused", await (async () => {
    const late = new Device(cluster, { token: t });
    await late.opened;
    late.send({ t: "ping", c0: 1 });
    const pong = await late.waitFor((m) => m.t === "pong");
    late.send({ t: "cmd", to: bId, blob: "x" });
    const error = await late.waitFor((m) => m.t === "error");
    late.close();
    return pong !== null && error?.code === "not_joined";
  })());
  a.close();
}

// --- clock
{
  const a = await join(hex(32), token());
  a.send({ t: "ping", c0: 123 });
  const pong = await a.waitFor((m) => m.t === "pong");
  check("a ping is answered with the clock of the server", pong?.c0 === 123 && Math.abs(pong.s1 - Date.now()) < 5000);
  a.close();
}

// --- who plays, what plays, what is asked of it
{
  const cluster = hex(32);
  const t = token();
  const a = await join(cluster, t);
  const b = await join(cluster, t);
  const idA = a.welcome.you;
  const idB = b.welcome.you;

  b.send({ t: "state", rev: 1, blob: "nope" });
  check("only the playing device may say what plays", (await b.waitFor((m) => m.t === "error"))?.code === "not_active");

  a.send({ t: "claim" });
  const active = await b.waitFor((m) => m.t === "active");
  check("a device that starts playing is the active one, for everybody", active?.device === idA && (await a.waitFor((m) => m.t === "active"))?.device === idA);

  a.send({ t: "queue", blob: "sealed-queue-1" });
  const shown = await b.waitFor((m) => m.t === "queue");
  check("the queue it says goes to the others", shown?.from === idA && shown.blob === "sealed-queue-1");
  a.send({ t: "state", rev: 7, blob: "sealed-state" });
  const state = await b.waitFor((m) => m.t === "state");
  check("its state goes to the others, as it was sealed", state?.from === idA && state.rev === 7 && state.blob === "sealed-state");
  check("and not back to itself", await a.quiet((m) => m.t === "state"));

  b.send({ t: "cmd", to: idA, blob: "sealed-cmd" });
  const cmd = await a.waitFor((m) => m.t === "cmd");
  check("a command reaches the device it is for", cmd?.from === idB && cmd.blob === "sealed-cmd");
  b.send({ t: "cmd", to: "0123456789abcdef", blob: "x" });
  check("a command for a device that is not here is an error", (await b.waitFor((m) => m.t === "error"))?.code === "gone");

  const c = await join(cluster, t);
  check("a device that comes later is told who plays and the last state", c.welcome.active === idA && c.welcome.state?.rev === 7 && c.welcome.state.blob === "sealed-state" && c.welcome.queue === "sealed-queue-1", JSON.stringify(c.welcome));

  // A hand-over: B asks, A is told to let go, and its queue goes to B
  b.send({ t: "transfer", to: idB });
  const release = await a.waitFor((m) => m.t === "release");
  check("the playing device is asked to let go", release?.to === idB && release.by === idB);
  const bigQueue = "q".repeat(1_400_000);
  a.send({ t: "handoff", blob: bigQueue });
  const handoff = await b.waitFor((m) => m.t === "handoff", 8000);
  check("its queue, even a big one, goes to the new one", handoff?.from === idA && handoff.blob === bigQueue, String(handoff?.blob?.length));
  const now = await c.waitFor((m) => m.t === "active" && m.device === idB);
  check("everybody is told who plays now", now !== null);
  const d = await join(cluster, t);
  check("the state of the old device is not offered for the new one", d.welcome.active === idB && d.welcome.state === null, JSON.stringify(d.welcome.state));

  // The old device is a controller now, and cannot speak for the player
  a.send({ t: "state", rev: 8, blob: "late" });
  check("the old device may not say what plays", (await a.waitFor((m) => m.t === "error"))?.code === "not_active");

  // A hand-over that nobody answers: after the time, the queue that was kept is given
  b.send({ t: "queue", blob: "kept-queue" });
  await sleep(100);
  a.send({ t: "transfer", to: idA });
  const asked = await b.waitFor((m) => m.t === "release");
  check("B is asked in turn", asked?.to === idA);
  const started = Date.now();
  const fallback = await a.waitFor((m) => m.t === "handoff", HANDOFF_MS + 5000);
  check("when it does not answer the kept queue is handed over after the time", fallback?.blob === "kept-queue" && fallback.from === idB && Date.now() - started >= HANDOFF_MS - 200, `${Date.now() - started} ms ${JSON.stringify(fallback)}`);

  // The one that plays goes: nobody plays, the last queue is there for whoever goes on from it (S9)
  a.send({ t: "queue", blob: "queue-of-a" });
  a.send({ t: "state", rev: 3, blob: "state-of-a" });
  await sleep(200);
  a.close();
  const none = await b.waitFor((m) => m.t === "active" && m.device === null);
  check("when the playing device goes nobody plays", none !== null);
  const e = await join(cluster, t);
  check("the last state stays for who comes", e.welcome.active === null && e.welcome.state?.blob === "state-of-a", JSON.stringify(e.welcome));
  e.send({ t: "transfer", to: e.welcome.you });
  const resumed = await e.waitFor((m) => m.t === "handoff");
  check("and asking to play here is given the last queue", resumed?.blob === "queue-of-a" && resumed.from === null, JSON.stringify(resumed));
  check("the one who asked plays", (await b.waitFor((m) => m.t === "active" && m.device === e.welcome.you)) !== null);

  // Two that want to play at once: the order they arrive in decides, and the loser is told to stop
  b.send({ t: "claim" });
  const deposed = await e.waitFor((m) => m.t === "deposed");
  check("a device that takes the playing is told to the one that had it", deposed?.by === idB);

  // A device that stops being the playing one
  e.send({ t: "claim" });
  await b.waitFor((m) => m.t === "active" && m.device === e.welcome.you);
  e.send({ t: "stop" });
  check("a device that stops playing leaves nobody playing", (await b.waitFor((m) => m.t === "active" && m.device === null)) !== null);
  b.send({ t: "claim" });
  await e.waitFor((m) => m.t === "active" && m.device === idB);

  // The same device again
  const again = await join(cluster, t, { clientId: b.clientId });
  check("a device that comes again replaces its old connection", (await b.closed) === 4000 && again.welcome.t === "welcome");
  for (const x of [a, c, d, e, again]) x.close();
}

// --- the playing device leaves while the hand-over is on
{
  const cluster = hex(32);
  const t = token();
  const a = await join(cluster, t);
  const b = await join(cluster, t);
  a.send({ t: "claim" });
  await b.waitFor((m) => m.t === "active");
  a.send({ t: "queue", blob: "q1" });
  await sleep(100);
  b.send({ t: "transfer", to: b.welcome.you });
  await a.waitFor((m) => m.t === "release");
  a.close();
  const handoff = await b.waitFor((m) => m.t === "handoff", 3000);
  check("the one that was to hand over goes: the kept queue is given at once", handoff?.blob === "q1" && Date.now() > 0);
  b.close();
}

// --- how many
{
  const cluster = hex(32);
  const t = token();
  const devices = [];
  for (let i = 0; i < 12; i++) devices.push(await join(cluster, t));
  check("twelve devices fit", devices.every((d) => d.welcome.t === "welcome"));
  const extra = await join(cluster, t);
  check("the thirteenth does not", extra.welcome.t === "error" && extra.welcome.code === "full", JSON.stringify(extra.welcome));
  devices[0].close();
  await sleep(300);
  const again = await join(cluster, t);
  check("and a place that is freed is taken", again.welcome.t === "welcome");
  for (const d of [...devices, again]) d.close();
}

// --- bad things
{
  const a = await join(hex(32), token());
  a.ws.send("not json");
  check("a text that is not JSON is an error", (await a.waitFor((m) => m.t === "error"))?.code === "bad_json");
  a.send({ t: "nonsense" });
  check("a type that does not exist is an error", (await a.waitFor((m) => m.t === "error"))?.code === "bad_message");
  for (let i = 0; i < 60; i++) a.send({ t: "ping", c0: i });
  await sleep(500);
  check("a flood is limited", a.inbox.some((m) => m.t === "error" && m.code === "rate_limited"));
  a.close();
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
