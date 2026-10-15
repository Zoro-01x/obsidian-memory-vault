#!/usr/bin/env node
// smoke-test.mjs -- end-to-end check of the vault MCP server over real stdio.
//
// READ-ONLY BY DESIGN: it must be safe to run at any time, including from a
// session that is mid-work, so it never creates, appends or proposes. Write
// verbs are covered by the adapter tests, not here.
//
//   node C:/Users/Home/Documents/ObsidianVault/.system/smoke-test.mjs
//
// Exit code 0 = all assertions passed.

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const SERVER = fileURLToPath(new URL("./vault-mcp.mjs", import.meta.url));
const TIMEOUT_MS = 60_000;

const results = [];
function check(name, pass, detail = "") {
  results.push({ name, pass, detail });
  console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? ` -- ${detail}` : ""}`);
}

const child = spawn("node", [SERVER], { stdio: ["pipe", "pipe", "pipe"] });
let buf = "";
const replies = new Map();
const unparseable = [];
let stderr = "";

child.stdout.setEncoding("utf8");
child.stdout.on("data", (d) => {
  buf += d;
  let idx;
  while ((idx = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (!line) continue;
    // Every stdout line must be valid JSON-RPC: a stray println corrupts the
    // whole stream and the client silently loses the connection.
    try {
      const msg = JSON.parse(line);
      if (msg.id !== undefined && msg.id !== null) replies.set(msg.id, msg);
      else unparseable.push(line);
    } catch {
      unparseable.push(line);
    }
  }
});
child.stderr.setEncoding("utf8");
child.stderr.on("data", (d) => { stderr += d; });

function send(msg) {
  child.stdin.write(JSON.stringify(msg) + "\n");
}
const call = (id, name, args) =>
  send({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args || {} } });

const deadline = Date.now() + TIMEOUT_MS;
const need = new Set([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
const wanted = [...need];

try {
  send({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "smoke", version: "0" } },
  });
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  send({ jsonrpc: "2.0", id: 3, method: "ping" });

  call(4, "core", { maxTokens: 400 });
  call(5, "recall", { query: "driver" });
  call(6, "read", { path: "CORE.md", backlinks: false });
  call(7, "read", { path: "entities/Does Not Exist.md" });          // must be isError
  call(8, "no_such_tool", {});                                      // must be -32602
  send({ jsonrpc: "2.0", id: 9, method: "bogus/method" });          // must be -32601
  call(10, "stale", { inboxDays: 7, verifiedDays: 90 });

  // Wait for every reply, then half-close stdin to prove in-flight draining.
  while (Date.now() < deadline && [...need].some((id) => !replies.has(id))) {
    await new Promise((r) => setTimeout(r, 50));
  }
} finally {
  child.stdin.end();
}

check(
  "all 10 responses arrived before timeout",
  wanted.every((id) => replies.has(id)),
  `missing: [${wanted.filter((id) => !replies.has(id)).join(", ")}]`,
);
check("every stdout line was valid JSON-RPC", unparseable.length === 0, unparseable.slice(0, 2).join(" | "));

const init = replies.get(1)?.result;
check(
  "initialize returns protocol + serverInfo",
  Boolean(init?.protocolVersion && init?.serverInfo?.name === "vault" && init?.capabilities?.tools),
  init ? `protocol=${init.protocolVersion} server=${init.serverInfo.name}` : "no reply",
);

const tools = replies.get(2)?.result?.tools ?? [];
const expected = ["core", "recall", "read", "create", "append", "propose", "stale"];
check(
  "tools/list exposes exactly the 7 verbs",
  JSON.stringify([...tools].map((t) => t.name).sort()) === JSON.stringify([...expected].sort()),
  tools.map((t) => t.name).join(", "),
);
check(
  "every tool has a description and an object schema",
  tools.every((t) => typeof t.description === "string" && t.description.length > 40 && t.inputSchema?.type === "object"),
);
check("ping answered", JSON.stringify(replies.get(3)?.result) === "{}");

const coreTxt = replies.get(4)?.result?.content?.[0]?.text ?? "";
const coreCap = 400 * 4; // maxTokens * ~4 chars/token, as enforced by Get-VaultCore
const coreTruncated = coreTxt.endsWith("[core truncated to budget]");
check("core returns the budget-capped index", coreTxt.includes("Memory"), `${coreTxt.length} chars @maxTokens 400`);
check(
  "core respects the 400-token cap (cap + truncation marker)",
  coreTruncated || coreTxt.length <= coreCap,
  `${coreTxt.length} chars vs cap ${coreCap}${coreTruncated ? " + 30-char marker (cap engaged)" : ""}`,
);
check("core marker present when over budget", coreTruncated, coreTruncated ? "truncated" : "not truncated");

const recallTxt = replies.get(5)?.result?.content?.[0]?.text ?? "";
check("recall finds the Intel driver lesson", recallTxt.includes("Intel"), recallTxt.split("\n")[0]);
check("recall returns vault-relative paths (not absolute)", !/^[A-Za-z]:[\\/]/.test(recallTxt.split("\n")[0] ?? ""), recallTxt.split("\n")[0]);

const readTxt = replies.get(6)?.result?.content?.[0]?.text ?? "";
check("read returns frontmatter + body", readTxt.includes("status:") && readTxt.includes("---"), `${readTxt.length} chars`);

check(
  "missing note is an isError result, not a crash",
  replies.get(7)?.result?.isError === true,
  (replies.get(7)?.result?.content?.[0]?.text ?? "").slice(0, 80),
);
check(
  "unknown tool -> -32602",
  replies.get(8)?.error?.code === -32602,
  JSON.stringify(replies.get(8)?.error ?? null),
);
check("unknown method -> -32601", replies.get(9)?.error?.code === -32601, JSON.stringify(replies.get(9)?.error ?? null));

const staleTxt = replies.get(10)?.result?.content?.[0]?.text ?? "";
check("stale returns a readable report", staleTxt.length > 5, staleTxt.split("\n")[0]);
check("no server crashed / no stderr error", !/handler crashed|adapter error/.test(stderr), stderr.split("\n").filter(Boolean).slice(-1)[0] || "clean");

child.kill();

const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
