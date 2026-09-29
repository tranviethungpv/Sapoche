// Starts local servers with a shared secret, runs the simulation against them, then stops them.
// Usage: npm run sim:keyed
//
// Two servers: one with the real timers for the whole protocol, and one whose timers for dead
// connections and empty rooms are seconds long, so "gone after a week" can be watched.
import { spawn } from "node:child_process";

const KEY = "simulation-key";

function startServer(port, vars, persistTo) {
  // Each dev server needs its own inspector port and its own state directory
  const args = ["wrangler", "dev", "--port", String(port), "--inspector-port", String(port + 100), "--persist-to", persistTo, "--var", `ROOM_KEY:${KEY}`];
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

function simulate(port, env) {
  return new Promise((resolve) => {
    const sim = spawn("node", ["scripts/sim.mjs", `http://127.0.0.1:${port}`], {
      stdio: "inherit",
      env: { ...process.env, UNISON_KEY: KEY, ...env },
    });
    sim.on("exit", resolve);
  });
}

const main = startServer(8798, { STALE_MS: 2000 }, ".wrangler/state");
const quick = startServer(
  8799,
  { STALE_MS: 2000, DROP_MS: 2500, SWEEP_MS: 1000, EMPTY_MS: 6000, EMPTY_BARE_MS: 1500 },
  ".wrangler/state-lifetime",
);

let code = 1;
try {
  await Promise.all([waitUntilUp(8798), waitUntilUp(8799)]);
  code = (await simulate(8798, { SIM_STALE_MS: "2000" })) ?? 1;
  if (code === 0) code = (await simulate(8799, { SIM_ONLY: "lifetime" })) ?? 1;
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
