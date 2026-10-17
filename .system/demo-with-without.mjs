#!/usr/bin/env node
// demo-with-without.mjs -- does memory change the answer?
//
// WHY THIS EXISTS
//   The other suites prove the plumbing: 7 verbs respond, bad writes are
//   refused, the wrapper starts cold. None of them shows the CLAIM, which is
//   that a session with this vault knows something a session without it does
//   not. This script runs one identical task twice and changes exactly one
//   variable: whether the memory holds the note that carries the answer.
//
//   Run A (memory present)  -> recall returns the decision -> correct answer
//   Run B (memory absent)   -> recall returns nothing       -> no answer exists
//
//   The difference between those two outputs IS the demo.
//
// WHAT IT TOUCHES
//   Nothing real. It builds a throwaway vault under %TEMP% carrying a
//   .vault-test-root sentinel, seeds it with FABRICATED notes about an
//   imaginary project, and removes it at the end. vault-lib.ps1 only honors
//   OBSIDIAN_VAULT_ROOT when the target is inside %TEMP% AND carries that
//   sentinel -- so the real vault is unreachable by construction, not by
//   good manners.
//
// HONESTY NOTE -- READ BEFORE QUOTING THIS OUTPUT
//   There is no LLM in this loop. "Session A" and "Session B" are two fresh
//   cold spawns of the real MCP server; the "answer" is what retrieval makes
//   available to an agent, not a model reasoning aloud. What this proves is
//   information availability: with memory the fact is one recall away, without
//   it the fact does not exist in the session. Do not describe this as an
//   agent "deciding" -- it did not decide anything.
//
// Run:
//   node .system/demo-with-without.mjs
//   node .system/demo-with-without.mjs --keep     # leave the vault for inspection
//
// Exit 0 = both runs behaved as expected (A finds it, B does not).

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, "vault-mcp.mjs");
const FOREIGN_CWD = "C:/Users/Home";   // deliberately not the vault
const TIMEOUT_MS = 45_000;
const KEEP = process.argv.includes("--keep");

// --- the fact under test ---------------------------------------------------
// A decision with a visible consequence: if you pick the conventional port you
// collide with the dashboard. Nothing else in the fixture depends on it.
const THE_PORT = 3001;
const THE_WRONG_PORT = 3000;

const results = [];
function check(name, pass, detail = "") {
  results.push({ name, pass });
  console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? ` -- ${detail}` : ""}`);
}
const line = (s = "") => console.log(s);

// --- fixture: fabricated notes, real 7-field schema ------------------------
const NOTES = [
  {
    folder: "decisions", name: "Harbor API port decision",
    description: "Harbor API binds 3001; 3000 is taken by the dev dashboard",
    aliases: ["api port", "harbor port", "which port"],
    scope: "harbor", basis: "observed", verified: "2026-10-16",
    body: [
      "The Harbor API runs on **3001**, never 3000.",
      "",
      "Port 3000 belongs to the dev dashboard and stays there. Binding 3000",
      "silently drops API traffic to the dashboard, which looks like a hang",
      "rather than a port clash because both accept the connection.",
      "",
      "Consequence: any service that must reach the API hardcodes 3001.",
    ].join("\n"),
  },
  {
    folder: "entities", name: "Harbor dev dashboard",
    description: "Dev dashboard owns port 3000 on every environment",
    aliases: ["dashboard port", "3000"], scope: "harbor",
    basis: "user-stated", verified: "2026-10-16",
    body: "The dev dashboard binds **3000** everywhere. Nothing else may use it.",
  },
  {
    folder: "decisions", name: "Harbor deploy target",
    description: "Harbor ships to the staging cluster, never prod directly",
    aliases: ["deploy target", "where does harbor ship"],
    scope: "harbor", basis: "observed", verified: "2026-10-16",
    body: "Harbor deploys to **staging**. Direct-to-prod pushes are refused by the pipeline.",
  },
  {
    folder: "lessons", name: "Harbor retry ceiling",
    description: "Retry ceiling is 3 attempts; more masks a real fault",
    aliases: ["retry limit", "retries"], scope: "harbor",
    basis: "observed", verified: "2026-10-16",
    body: "Retry ceiling is **3 attempts**. Beyond that a retry loop hides the underlying fault.",
  },
  {
    folder: "entities", name: "Harbor cache key format",
    description: "Cache keys are namespaced svc:region:id",
    aliases: ["cache key", "key format"], scope: "harbor",
    basis: "inferred", status: "active", verified: "2026-10-16",
    body: "Cache keys are namespaced `svc:region:id`. Inferred from two call sites, not documented.",
  },
];

function makeVault(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  writeFileSync(join(root, ".vault-test-root"), "synthetic demo vault -- not the real one\n", "utf8");
  writeFileSync(join(root, "CORE.md"),
    "---\nname: CORE\n---\n\n# CORE\n\nSynthetic demo vault. Everything in here is fabricated.\n", "utf8");
  const g = spawnSync("git", ["init", "-q"], { cwd: root, encoding: "utf8" });
  if (g.status !== 0) throw new Error("git init failed: " + (g.error?.message || g.status));
  spawnSync("git", ["config", "user.name", "demo"], { cwd: root });
  spawnSync("git", ["config", "user.email", "demo@vault.local"], { cwd: root });
  // Line-ending normalization OFF, exactly as write-validation-test.ps1 does.
  // With default autocrlf, git warns on stderr about LF/CRLF on every `add`,
  // and under the adapter's $ErrorActionPreference='Stop' a native command's
  // stderr becomes a terminating error. A throwaway repo has no working-copy
  // history to preserve, so there is nothing for normalization to protect.
  spawnSync("git", ["config", "core.autocrlf", "false"], { cwd: root });
  spawnSync("git", ["config", "core.safecrlf", "false"], { cwd: root });
  return root;
}

// --- one cold MCP session, exactly as OpenCode would spawn it ---------------
function session(root, label) {
  const child = spawn("node", [SERVER], {
    cwd: FOREIGN_CWD,                       // foreign cwd: the cold-start point
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, OBSIDIAN_VAULT_ROOT: root },
  });
  let buf = "";
  const replies = new Map();
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const raw = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!raw) continue;
      try { const m = JSON.parse(raw); if (m.id !== undefined && m.id !== null) replies.set(m.id, m); }
      catch { /* stray println would corrupt the stream; surfaced below */ }
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (d) => { stderr += d; });
  // A killed child closes stdin first; without this the next write throws an
  // unhandled EPIPE and takes the whole demo down with it.
  child.stdin.on("error", () => {});

  const send = (m) => child.stdin.write(JSON.stringify(m) + "\n");
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  async function wait(id, ms = TIMEOUT_MS) {
    const end = Date.now() + ms;
    while (Date.now() < end) { if (replies.has(id)) return replies.get(id); await sleep(60); }
    return null;
  }
  const call = (id, name, args) =>
    send({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args || {} } });

  return { child, send, wait, call, replies, stderr, close: () => { try { child.kill(); } catch {} } };
}

const toolText = (r) => r?.result?.content?.[0]?.text ?? "";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- parsers for the server's TEXT output (formatResult, not JSON) ---------
// recall -> `No notes matched "..."`  |  `- path\n    desc\n    [score .. basis .. status .. verified ..]`
function parseRecall(text) {
  if (!text || /^No notes matched/.test(text.trim())) return [];
  const hits = [];
  for (const raw of text.split("\n")) {
    const l = raw.trimEnd();
    if (l.startsWith("- ")) {
      hits.push({ path: l.slice(2).trim(), description: "", score: null, basis: "", status: "", verified: "" });
      continue;
    }
    const cur = hits[hits.length - 1];
    if (!cur) continue;
    const meta = l.match(/\[([^\]]+)\]/);
    if (meta) {
      for (const part of meta[1].split("·")) {
        const p = part.trim();                 // leading space makes split(/\\s+/) yield ""
        if (!p) continue;
        const [k, ...rest] = p.split(/\s+/);
        const v = rest.join(" ").trim();
        if (k === "score") cur.score = v;
        else if (k === "basis") cur.basis = v;
        else if (k === "status") cur.status = v;
        else if (k === "verified") cur.verified = v;
      }
    } else if (l.startsWith("    ")) {
      cur.description = l.trim();
    }
  }
  return hits;
}

// read -> `path: X\n---\n<frontmatter>\n---\nbacklinks: ...\n\n<body>`
// The BODY only: the note's own description field also mentions the port, and
// quoting that would let a run "pass" without ever reaching the body.
function parseRead(text) {
  const lines = (text || "").split("\n");
  const seps = [];
  lines.forEach((l, i) => { if (l.trim() === "---") seps.push(i); });
  if (seps.length < 2) return { frontmatter: "", body: text || "" };
  const frontmatter = lines.slice(seps[0] + 1, seps[1]).join("\n");
  let rest = lines.slice(seps[1] + 1);
  if (rest.length && /^backlinks:/.test(rest[0])) rest = rest.slice(1);
  while (rest.length && rest[0].trim() === "") rest.shift();   // the blank separator
  return { frontmatter, body: rest.join("\n") };
}

// =====================================================================
line("");
line("=== WITH / WITHOUT: does memory change what a cold session knows? ===");
line("");
line("Task given identically to both runs:");
line(`  \"The Harbor API needs a port. Which one, and why not the obvious one?\"`);
line("");

// ---------- build the two vaults -------------------------------------
const rootA = makeVault("vault-demo-A-");
const rootB = makeVault("vault-demo-B-");
console.log(`synthetic vault A (memory present): ${rootA}`);
console.log(`synthetic vault B (memory absent) : ${rootB}`);
console.log(`real vault in play                : none -- %TEMP% + sentinel enforced by vault-lib.ps1`);

// =====================================================================
line("");
line("--- RUN A -- Session A writes the decision, Session B reads it back ---");

// Session A: write through the real `create` verb (validation + commit path)
{
  const A = session(rootA, "A");
  A.send({ jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "demo-A", version: "0" } } });
  const init = await A.wait(1);
  check("Session A: cold start answered", !!init, init ? `protocol=${init.result?.protocolVersion}` : "no reply");
  A.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  let created = 0;
  for (const n of NOTES) {
    A.call(100 + created, "create", {
      folder: n.folder, name: n.name, description: n.description,
      body: n.body, aliases: n.aliases, basis: n.basis,
      scope: n.scope || "harbor", verified: n.verified, status: n.status || "active",
      author: "demo",
    });
    const r = await A.wait(100 + created);
    const ok = !!r?.result && r.result.isError !== true;
    if (ok) created++;
    else check(`Session A: create '${n.name}'`, false, toolText(r).slice(0, 160));
  }
  check("Session A: wrote all 5 fabricated notes through `create`", created === NOTES.length, `${created}/5`);
  A.close();
}
line("  Session A exits. Memory now holds 5 notes.");

// Session B: FRESH cold spawn, foreign cwd, must recall the fact
{
  const B = session(rootA, "B");   // memory PRESENT: the vault Session A just wrote
  B.send({ jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "demo-B", version: "0" } } });
  const init = await B.wait(1);
  check("Session B: cold start answered", !!init, init ? `server=${init.result?.serverInfo?.name}` : "no reply");
  B.send({ jsonrpc: "2.0", method: "notifications/initialized" });

  // The task: one recall, then read the note retrieval returned.
  B.call(2, "recall", { query: "which port does the harbor api use", limit: 5 });
  const rec = await B.wait(2);
  const hits = parseRecall(toolText(rec));
  const top = hits[0];

  line("");
  line(`  recall "which port does the harbor api use"  -> ${hits.length} hit(s)`);
  for (const h of hits.slice(0, 3)) line(`    ${h.path}  [basis=${h.basis}  status=${h.status}  score=${h.score}]`);

  check("Session B: recall returned the decision note", !!top,
    top ? `${top.path} score=${top.score}` : "0 hits");

  if (top) {
    B.call(3, "read", { path: top.path, backlinks: false });
    const rd = await B.wait(3);
    const { body } = parseRead(toolText(rd));
    const found = [...new Set(body.match(/\b300[0-9]\b/g) || [])];
    // The note MUST mention 3000 (the task asks why not the obvious one), so
    // "3000 appears" proves nothing. What matters is the actual assertion:
    // which port the API is said to run on.
    const correct = /API runs on \*\*3001\*\*/.test(body);
    const says3000IsOurs = /API runs on \*\*3000\*\*/.test(body);
    check("Session B: read returned the note body", body.length > 0, `${body.length} chars`);
    check(`Session B: note asserts the API runs on ${THE_PORT}`, correct && !says3000IsOurs,
      `body names ${found.join(", ") || "no ports"}; assertion found: ${correct}`);
    line(`  -> Answer available to the session: ${correct ? THE_PORT : "unknown"}`);
    line(`     Provenance: basis=${top.basis}, verified=${top.verified}, status=${top.status}`);
  } else {
    line("  -> No answer available.");
  }
  B.close();
}

// =====================================================================
line("");
line("--- RUN B -- identical task, memory absent (empty vault) ---");
{
  const C = session(rootB, "C");      // empty synthetic vault: no memory content
  C.send({ jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "demo-C", version: "0" } } });
  const init = await C.wait(1);
  check("Control: cold start answered", !!init, init ? `server=${init.result?.serverInfo?.name}` : "no reply");
  C.send({ jsonrpc: "2.0", method: "notifications/initialized" });

  C.call(2, "recall", { query: "which port does the harbor api use", limit: 5 });
  const rec = await C.wait(2);
  const hits = parseRecall(toolText(rec));

  line("");
  line(`  recall "which port does the harbor api use"  -> ${hits.length} hit(s)`);
  line(hits.length === 0 ? "    (nothing)" : hits.map(h => `    ${h.path}`).join("\n"));

  // Mirrors Run A exactly: recall, then read the top hit. The control does NOT
  // require zero hits -- an unrelated match (CORE.md) is not the point, and
  // demanding an empty result would rig the comparison. What must differ is
  // whether the ANSWER is available.
  let answerAvailable = false;
  let provenance = "n/a";
  if (hits[0]) {
    C.call(3, "read", { path: hits[0].path, backlinks: false });
    const rd = await C.wait(3);
    const { body } = parseRead(toolText(rd));
    answerAvailable = /API runs on \*\*3001\*\*/.test(body);
    provenance = `top hit ${hits[0].path} (${body.length} chars)`;
  }

  check("Control: the answer is NOT available", !answerAvailable,
    answerAvailable ? "the fact WAS retrievable -- demo does not separate" : `nothing retrieved states the port (${provenance})`);
  line(`  -> Answer available to the session: ${answerAvailable ? THE_PORT : "none"}`);
  line(`     The conventional default (${THE_WRONG_PORT}) is what a developer would assume,`);
  line(`     and it collides with the dev dashboard.`);
  C.close();
}

// =====================================================================
line("");
line("--- VERDICT ---");
const a = results.find(r => r.name.startsWith("Session B: note asserts"));
const b = results.find(r => r.name.startsWith("Control: the answer is NOT"));
if (a?.pass && b?.pass) {
  line(`  WITH memory   : the fact is retrievable and carries provenance (basis/verified/status).`);
  line(`  WITHOUT memory: the fact does not exist in the session.`);
  line(`  Same task, same code path, same cold spawn -- the only variable is the note.`);
  line("");
  line(`  That difference is the claim. Everything else in this repo proves the plumbing.`);
} else {
  line("  Demo did NOT separate: see failed checks above.");
}

// ---------- cleanup / report ---------------------------------------
line("");
if (KEEP) {
  line(`--keep: synthetic vaults left at`);
  line(`  A: ${rootA}`);
  line(`  B: ${rootB}`);
} else {
  for (const [label, r] of [["A", rootA], ["B", rootB]]) {
    if (existsSync(r)) { try { rmSync(r, { recursive: true, force: true }); } catch {} }
  }
  line("synthetic vaults removed (%TEMP% only -- the real vault was never the target)");
}

const failed = results.filter(r => !r.pass).length;
line("");
line(`${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
