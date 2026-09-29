// Starts a local server with a shared secret, runs the simulation against it, then stops it.
// Usage: npm run sim:keyed
import { spawn } from "node:child_process";

const PORT = 8798;
const KEY = "simulation-key";
const server = spawn("npx", ["wrangler", "dev", "--port", String(PORT), "--var", `ROOM_KEY:${KEY}`, "--var", "STALE_MS:2000"], {
  stdio: ["ignore", "ignore", "inherit"],
  detached: true, // own process group, so the whole tree (npx, wrangler, workerd) can be stopped
});

async function waitUntilUp() {
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("server did not start");
}

let code = 1;
try {
  await waitUntilUp();
  code = await new Promise((resolve) => {
    const sim = spawn("node", ["scripts/sim.mjs", `http://127.0.0.1:${PORT}`], {
      stdio: "inherit",
      env: { ...process.env, UNISON_KEY: KEY, SIM_STALE_MS: "2000" },
    });
    sim.on("exit", resolve);
  });
} finally {
  try {
    process.kill(-server.pid, "SIGTERM");
  } catch {
    // already gone
  }
}
process.exit(code ?? 1);
