#!/usr/bin/env node
// cold-start-test.mjs -- does the MCP wrapper survive a COLD START?
//
// WHY THIS EXISTS SEPARATELY FROM smoke-test.mjs:
//   smoke-test runs in the session that built the wrapper. A wrapper can work
//   there and still fail when OpenCode relaunches it, because the session has
//   a working directory, a PATH and an environment that a fresh process does
//   not. This script reproduces the fresh case:
//
//     * it reads the REAL command and args out of opencode.jsonc, so a config
//       typo is caught here rather than at the next session,
//     * it spawns from an unrelated working directory (the repo root, not the
//       vault), so any hidden dependence on cwd fails loudly,
//     * it checks that git and rg resolve in that fresh context. Both were
//       installed portable under the user PATH, and a newly launched OpenCode
//       may not inherit a PATH edited mid-session -- the likeliest culprit.
//
// Run after ANY change to vault-mcp.mjs, vault-adapter.ps1, vault-lib.ps1,
// opencode.jsonc, or a Node upgrade.
//
//   node .system/cold-start-test.mjs
//     -> the wrapper opencode.jsonc declares. Proves the real config still
//        launches cold. Keep doing this after config changes.
//
//   node .system/cold-start-test.mjs --wrapper <clone>/.system/vault-mcp.mjs
//     -> CLONE MODE for a restore proof. Proves the RESTORED wrapper code
//        starts, and points OBSIDIAN_VAULT_ROOT at the clone so the restored
//        library reads the restored vault instead of the live one. The path is
//        honored only under %TEMP% inside a directory carrying the
//        .vault-test-root sentinel, or it exits 2 before spawning.
//
// Exit code 0 = the wrapper comes up cold and exposes all 7 tools.

import { spawn, spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
// Deliberately NOT the vault: an unrelated cwd is the whole point.
const FOREIGN_CWD = "C:/Users/Home";
const CONFIG = "C:/Users/Home/.config/opencode/opencode.jsonc";
const TIMEOUT_MS = 30_000;
const EXPECTED = ["core", "recall", "read", "create", "append", "propose", "stale", "verify"];

const results = [];
function check(name, pass, detail = "") {
  results.push({ name, pass });
  console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? ` -- ${detail}` : ""}`);
}

// --- read the command OpenCode itself would run ---------------------------
// JSONC, so strip comments first. Only // line comments exist in this file;
// a full parser is not worth it here, but the string-scan below refuses to
// strip anything inside a quoted string so URLs survive.
function readJsonc(path) {
  const src = readFileSync(path, "utf8");
  let out = "";
  let inStr = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (inStr) {
      out += c;
      if (c === "\\") { out += src[++i] ?? ""; continue; }
      if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; out += c; continue; }
    if (c === "/" && src[i + 1] === "/") {
      while (i < src.length && src[i] !== "\n") i++;
      out += "\n";
      continue;
    }
    out += c;
  }
  return JSON.parse(out);
}

let serverCmd = null;
try {
  const cfg = readJsonc(CONFIG);
  const vault = cfg?.mcp?.servers?.vault;
  if (!vault?.command?.length) throw new Error("mcp.servers.vault.command is missing");
  serverCmd = vault.command;
  check("opencode.jsonc parsed and vault command found", true, serverCmd.join(" "));
} catch (e) {
  check("opencode.jsonc parsed and vault command found", false, e.message);
  finish();
}

// --- two modes, deliberately different claims ------------------------------
//
// DEFAULT (no argument): spawn the wrapper opencode.jsonc declares. This
//   proves the real config still launches cold and that the live wrapper
//   works. Keep running it after any config change.
//
// --wrapper <path> (CLONE MODE): spawn a RESTORED copy, which is what a
//   restore proof actually needs. A caller-supplied path is code execution, so
//   it is honored under the same rule as the VaultRoot override: the path must
//   sit under %TEMP% inside a directory carrying a .vault-test-root sentinel,
//   or this exits 2 before spawning anything.
//
//   Why clone mode also sets the root: a clone's library defaults to the LIVE
//   vault (vault-lib.ps1 hardcodes its root), so a clone's wrapper silently
//   reads live data unless OBSIDIAN_VAULT_ROOT and the sentinel are both set.
//   Found 2026-10-15 by canary note -- "7/7 passed on the clone" had never
//   been evidence that the clone was what got tested.
const argv = process.argv.slice(2);
let wrapperArg = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--wrapper") wrapperArg = argv[++i];
}

const tempRoot = (process.env.TEMP || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
let intendedWrapper = null;
let childEnv = { ...process.env };

if (wrapperArg) {
  const full = resolve(wrapperArg).replace(/\\/g, "/");
  const wrapperDir = dirname(full);
  const cloneRoot = dirname(wrapperDir).replace(/\\/g, "/").replace(/\/+$/, "");
  const underTemp = cloneRoot.toLowerCase().startsWith(tempRoot + "/");
  const sentinel = existsSync(join(cloneRoot, ".vault-test-root"));
  if (!underTemp || !sentinel) {
    console.log(`ABORT: refusing --wrapper ${full}`);
    console.log(`  under %TEMP% : ${underTemp}`);
    console.log(`  sentinel     : ${sentinel}`);
    console.log("A caller-supplied wrapper is code execution; it must look like a restore target.");
    process.exit(2);
  }
  intendedWrapper = full;
  childEnv.OBSIDIAN_VAULT_ROOT = cloneRoot;
} else {
  // The wrapper is the argument in the configured command that names an .mjs.
  intendedWrapper = (serverCmd.find((a) => /\.mjs$/i.test(a)) || "").replace(/\\/g, "/");
}

function finish() {
  const failed = results.filter((r) => !r.pass).length;
  console.log("");
  console.log(`${results.length - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

// --- do the sibling tools resolve in a fresh process? ---------------------
// This is the check that catches "git/rg are on my PATH but not on OpenCode's".
for (const [label, exe] of [["git", "git"], ["rg", "rg"]]) {
  const r = spawnSync(exe, ["--version"], { cwd: FOREIGN_CWD, encoding: "utf8", timeout: 10_000 });
  check(
    `${label} resolves from a fresh cwd`,
    r.status === 0,
    r.status === 0 ? (r.stdout || "").trim().split("\n")[0] : (r.error?.message || `exit ${r.status}`)
  );
}

// --- spawn the wrapper exactly as OpenCode would ---------------------------
// In clone mode the configured command names the LIVE wrapper, so the spawn is
// built from the validated path instead. Printing and asserting the path means
// a future edit cannot quietly make this test claim the clone while running
// the live wrapper again -- which is exactly what it used to do.
const [cmd, ...args] = wrapperArg ? ["node", intendedWrapper] : serverCmd;
const spawnedWrapper = (args[args.length - 1] || "").replace(/\\/g, "/");
console.log(`spawned wrapper: ${spawnedWrapper}${wrapperArg ? "  (clone mode)" : "  (from opencode.jsonc)"}`);
check(
  "spawned the intended wrapper",
  spawnedWrapper === intendedWrapper,
  `intended ${intendedWrapper}`
);
const child = spawn(cmd, args, { cwd: FOREIGN_CWD, stdio: ["pipe", "pipe", "pipe"], env: childEnv });

let buf = "";
const replies = new Map();
let stderr = "";

child.stdout.setEncoding("utf8");
child.stdout.on("data", (d) => {
  buf += d;
  let idx;
  while ((idx = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (!line) continue;
    try {
      const msg = JSON.parse(line);
      if (msg.id !== undefined && msg.id !== null) replies.set(msg.id, msg);
    } catch {
      // A stray println would corrupt the stream; surfaced as a failed check.
      check("stdout carried only valid JSON-RPC", false, line.slice(0, 120));
    }
  }
});
child.stderr.setEncoding("utf8");
child.stderr.on("data", (d) => { stderr += d; });

child.on("error", (e) => {
  check("wrapper process spawned", false, e.message);
  finish();
});

const send = (msg) => child.stdin.write(JSON.stringify(msg) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(id, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (replies.has(id)) return replies.get(id);
    await sleep(100);
  }
  return null;
}

const initTimer = setTimeout(() => {
  check("initialize answered within the startup budget", false, `no reply in ${TIMEOUT_MS}ms`);
  try { child.kill(); } catch {}
  finish();
}, TIMEOUT_MS);

try {
  send({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "cold-start", version: "0" } },
  });
  const init = await waitFor(1, TIMEOUT_MS);
  check("initialize answered within the startup budget", !!init,
    init ? `protocol=${init.result?.protocolVersion} server=${init.result?.serverInfo?.name}` : "no reply");
  if (!init) { clearTimeout(initTimer); finish(); }

  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  send({ jsonrpc: "2.0", id: 2, method: "tools/list" });

  const list = await waitFor(2, TIMEOUT_MS);
  const names = (list?.result?.tools ?? []).map((t) => t.name).sort();
  check("tools/list answered", !!list, `${names.length} tools`);
  check(
    "all 8 verbs exposed on a cold start",
    JSON.stringify(names) === JSON.stringify([...EXPECTED].sort()),
    names.join(", ")
  );

  // One real call, to prove the PowerShell adapter is reachable from here.
  send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "core", arguments: { maxTokens: 300 } } });
  const core = await waitFor(3, TIMEOUT_MS);
  check("core executes (adapter reachable)", !!core?.result, core?.result ? "returned content" : "no reply");
} catch (e) {
  check("cold start completed without throwing", false, e.message);
}

clearTimeout(initTimer);
try { child.kill(); } catch {}

if (stderr.trim()) {
  // Not automatically a failure -- the server logs its start line -- but it is
  // printed so a real error is visible rather than swallowed.
  console.log(`[stderr] ${stderr.trim().split("\n").slice(0, 4).join(" | ")}`);
}

setTimeout(finish, 300);
