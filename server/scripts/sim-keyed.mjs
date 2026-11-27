// Starts local servers with a shared secret, runs the simulation against them, then stops them.
// Usage: npm run sim:keyed (npm run stress also runs scripts/stress.mjs against the first server)
//
// Two servers: one with the real timers for the whole protocol, and one whose timers for dead
// connections and empty rooms are seconds long, so "gone after a week" can be watched.
import { execFileSync, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KEY = "simulation-key";
const MEDIA_SIGN = "simulation-media-sign";

function startServer(port, vars, persistTo) {
  // Each dev server needs its own inspector port and its own state directory; --local keeps every binding on this
  // machine, so a test never reaches the real bucket and needs no Cloudflare login
  const args = ["wrangler", "dev", "--local", "--port", String(port), "--inspector-port", String(port + 100), "--persist-to", persistTo, "--var", `ROOM_KEY:${KEY}`, "--var", `MEDIA_SIGN:${MEDIA_SIGN}`];
  for (const [name, value] of Object.entries(vars)) args.push("--var", `${name}:${value}`);
  return spawn("npx", args, {
    stdio: ["ignore", "ignore", "inherit"],
    detached: true, // own process group, so the whole tree (npx, wrangler, workerd) can be stopped
  });
}

async function waitUntilUp(port) {
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`server on port ${port} did not start`);
}

function simulate(port, env, script = "scripts/sim.mjs") {
  return new Promise((resolve) => {
    const sim = spawn("node", [script, `http://127.0.0.1:${port}`], {
      stdio: "inherit",
      env: { ...process.env, SAPOCHE_KEY: KEY, ...env },
    });
    sim.on("exit", resolve);
  });
}

/** Puts a release in the local bucket the first server reads, so the update routes have something to serve. */
function seedRelease(persistTo) {
  // What an earlier run left in the bucket must not be there: a stale file under another name would pass for the new one
  rmSync(join(persistTo, "v3", "r2"), { recursive: true, force: true });
  const dir = mkdtempSync(join(tmpdir(), "sapoche-release-"));
  const apk = randomBytes(5000);
  const gz = gzipSync(apk);
  const latest = { versionCode: 9, versionName: "9.9.9", sha256: createHash("sha256").update(apk).digest("hex"), size: apk.length, file: "sapoche-9.9.9.apk", gzFile: "sapoche-9.9.9.apk.gz", gzSize: gz.length, notes: "test" };
  writeFileSync(join(dir, "sapoche-9.9.9.apk"), apk);
  writeFileSync(join(dir, "sapoche-9.9.9.apk.gz"), gz);
  writeFileSync(join(dir, "latest.json"), JSON.stringify(latest));
  for (const [key, file] of [["sapoche-9.9.9.apk", "sapoche-9.9.9.apk"], ["sapoche-9.9.9.apk.gz", "sapoche-9.9.9.apk.gz"], ["latest.json", "latest.json"]]) {
    execFileSync("npx", ["wrangler", "r2", "object", "put", `sapoche-releases/${key}`, "--local", "--persist-to", persistTo, "--file", join(dir, file)], { stdio: "ignore" });
  }
  return { apk, latest };
}

// A Last.fm that is this process: it keeps the last form it was sent, which `/_last` gives back, and answers a token to the first call
const LASTFM_FAKE_PORT = 8797;
let lastfmLast = "";
const lastfmFake = createServer((req, res) => {
  if (req.method === "GET") {
    res.end(lastfmLast);
    return;
  }
  let text = "";
  req.on("data", (chunk) => (text += chunk));
  req.on("end", () => {
    lastfmLast = text;
    const method = new URLSearchParams(text).get("method");
    const answer = method === "auth.getToken" ? { token: "tok-1" } : method === "auth.getSession" ? { error: 14, message: "Unauthorized Token" } : { ok: 1 };
    res.writeHead(method === "auth.getSession" ? 403 : 200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(answer));
  });
});
lastfmFake.listen(LASTFM_FAKE_PORT, "127.0.0.1");

// The keys that sign pushes, made for this run: the private half never leaves this process and the server it starts
const vapid = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ format: "jwk" });
const vapidPublic = Buffer.concat([Buffer.of(4), Buffer.from(vapid.x, "base64url"), Buffer.from(vapid.y, "base64url")]).toString("base64url");
const PUSH_FRESH_MS = 3000;

// What an earlier run left in the account's ledger would count against the limit this one tests
rmSync(".wrangler/state-lifetime", { recursive: true, force: true });
const release = seedRelease(".wrangler/state");
const MEDIA_TICKET_MS = 3000;
const FILL_MS = 2500;
const main = startServer(8798, { STALE_MS: 2000, FILL_MS, SYNC_VERSION_GAP_MS: 0, CONNECT_HANDOFF_MS: 1500, MEDIA_FILE_MAX: 20_000, MEDIA_ROOM_MAX: 60_000, MEDIA_PER_DAY: 30, MEDIA_TICKET_MS, VAPID_PRIVATE: vapid.d, VAPID_PUBLIC: vapidPublic, PUSH_LOCAL: 1, PUSH_FRESH_MS, LASTFM_KEY: "test-key", LASTFM_SECRET: "test-secret", LASTFM_API: `http://127.0.0.1:${LASTFM_FAKE_PORT}/` }, ".wrangler/state");
const quick = startServer(
  8799,
  { STALE_MS: 2000, MEDIA_ACCOUNT_MAX: 10_000, DROP_MS: 2500, SWEEP_MS: 1000, EMPTY_MS: 6000, EMPTY_BARE_MS: 1500, CHAT_KEEP_MS: 4000, CHAT_KEEP_MAX: 20, CHAT_PRUNE_MS: 1, LASTFM_KEY: "", LASTFM_SECRET: "" },
  ".wrangler/state-lifetime",
);

let code = 1;
try {
  await Promise.all([waitUntilUp(8798), waitUntilUp(8799)]);
  code = (await simulate(8798, { SIM_STALE_MS: "2000", SIM_FILL_MS: String(FILL_MS), SIM_MEDIA_TICKET_MS: String(MEDIA_TICKET_MS), SIM_VAPID_PUBLIC: vapidPublic, SIM_LASTFM_FAKE: `http://127.0.0.1:${LASTFM_FAKE_PORT}`, SIM_NO_LASTFM: "http://127.0.0.1:8799", SIM_PUSH_FRESH_MS: String(PUSH_FRESH_MS), SIM_RELEASE: JSON.stringify({ apk: release.apk.toString("base64"), latest: release.latest }) })) ?? 1;
  if (code === 0) code = (await simulate(8798, {}, "scripts/sim-connect.mjs")) ?? 1;
  if (code === 0) code = (await simulate(8799, { SIM_ONLY: "lifetime" })) ?? 1;
  if (code === 0 && process.env.SIM_STRESS) code = (await simulate(8798, {}, "scripts/stress.mjs")) ?? 1;
} finally {
  lastfmFake.close();
  for (const server of [main, quick]) {
    try {
      process.kill(-server.pid, "SIGTERM");
    } catch {
      // already gone
    }
  }
}
process.exit(code);
