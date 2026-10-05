// Starts local servers with a shared secret, runs the simulation against them, then stops them.
// Usage: npm run sim:keyed (npm run stress also runs scripts/stress.mjs against the first server)
//
// Two servers: one with the real timers for the whole protocol, and one whose timers for dead
// connections and empty rooms are seconds long, so "gone after a week" can be watched.
import { execFileSync, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KEY = "simulation-key";

function startServer(port, vars, persistTo) {
  // Each dev server needs its own inspector port and its own state directory; --local keeps every binding on this
  // machine, so a test never reaches the real bucket and needs no Cloudflare login
  const args = ["wrangler", "dev", "--local", "--port", String(port), "--inspector-port", String(port + 100), "--persist-to", persistTo, "--var", `ROOM_KEY:${KEY}`];
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
  const latest = { versionCode: 9, versionName: "9.9.9", sha256: createHash("sha256").update(apk).digest("hex"), size: apk.length, file: "sapoche-9.9.9.apk", notes: "test" };
  writeFileSync(join(dir, "sapoche-9.9.9.apk"), apk);
  writeFileSync(join(dir, "latest.json"), JSON.stringify(latest));
  for (const [key, file] of [["sapoche-9.9.9.apk", "sapoche-9.9.9.apk"], ["latest.json", "latest.json"]]) {
    execFileSync("npx", ["wrangler", "r2", "object", "put", `sapoche-releases/${key}`, "--local", "--persist-to", persistTo, "--file", join(dir, file)], { stdio: "ignore" });
  }
  return { apk, latest };
}

const release = seedRelease(".wrangler/state");
const main = startServer(8798, { STALE_MS: 2000 }, ".wrangler/state");
const quick = startServer(
  8799,
  { STALE_MS: 2000, DROP_MS: 2500, SWEEP_MS: 1000, EMPTY_MS: 6000, EMPTY_BARE_MS: 1500 },
  ".wrangler/state-lifetime",
);

let code = 1;
try {
  await Promise.all([waitUntilUp(8798), waitUntilUp(8799)]);
  code = (await simulate(8798, { SIM_STALE_MS: "2000", SIM_RELEASE: JSON.stringify({ apk: release.apk.toString("base64"), latest: release.latest }) })) ?? 1;
  if (code === 0) code = (await simulate(8799, { SIM_ONLY: "lifetime" })) ?? 1;
  if (code === 0 && process.env.SIM_STRESS) code = (await simulate(8798, {}, "scripts/stress.mjs")) ?? 1;
} finally {
  for (const server of [main, quick]) {
    try {
      process.kill(-server.pid, "SIGTERM");
    } catch {
      // already gone
    }
  }
}
process.exit(code);
