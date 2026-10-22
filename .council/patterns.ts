// .council/patterns.ts -- Meta's pattern-recognition skill + the hot rail into
// Sam's RUNNING OpenCode chat (built 2026-10-22 on Sam's approval).
//
// Flow:
//   <digest-file>  (what happened in the working chat; the agent writes it)
//     -> fresh Meta chat (same lane as the council: no restored sessions)
//     -> strict-JSON PatternReport {patterns, corrections, reorg}
//     -> HOT RAIL: rewrite the "### Learned patterns" section of D:\Sam\AGENTS.md.
//        OpenCode pushes that file's diff into the live conversation as a
//        system-update (observed working 2026-10-22), so the very next user
//        message already runs on the new patterns. No restart, no next session.
//     -> DURABLE RAIL: one propose claim per batch through vault-adapter.ps1
//        (staged in inbox, receipts in .council/pattern-log.jsonl).
//
// Usage:
//   node .council/patterns.ts <digest-file> [--tab id] [--dry-run] [--no-agents]
// Env: SAM_AGENTS_MD overrides the hot-rail target (default D:/Sam/AGENTS.md).

import { readFileSync, writeFileSync, existsSync, appendFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { listTabs } from "../.io/util.ts";
import { askJson } from "../.io/ask.ts";
import type { Parsed } from "../.io/types.ts";
import { freshMetaChat } from "./council.ts";
import { patternPrompt } from "./prompts.ts";
import type { PatternReport } from "./prompts.ts";
import { callAdapter, asciiFold } from "./file.ts";

const LOG = fileURLToPath(new URL("./pattern-log.jsonl", import.meta.url));
const AGENTS_PATH = process.env.SAM_AGENTS_MD || "D:/Sam/AGENTS.md";
const HEADER_PREFIX = "### Learned patterns";
const MAX_ENTRIES = 30;
const STALE_MARKER = "PATTERN-RECOGNIZER";

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
function flag(name: string): boolean {
  return process.argv.includes("--" + name);
}

// --- strict validation of Meta's JSON --------------------------------------

function validateReport(v: unknown): PatternReport | null {
  const o = v as Record<string, unknown>;
  if (!o || typeof o !== "object") return null;
  const arr = (x: unknown): unknown[] => (Array.isArray(x) ? x : []);
  const patterns: PatternReport["patterns"] = [];
  for (const p of arr(o.patterns).slice(0, 5)) {
    const x = p as Record<string, unknown>;
    if (!x || typeof x.statement !== "string" || !x.statement.trim()) continue;
    const c = typeof x.confidence === "number" ? x.confidence : 0.5;
    patterns.push({
      statement: x.statement.trim().slice(0, 200),
      evidence: String(x.evidence ?? "").trim().slice(0, 240),
      confidence: c >= 0 && c <= 1 ? c : 0.5,
    });
  }
  const corrections: PatternReport["corrections"] = [];
  for (const c of arr(o.corrections).slice(0, 4)) {
    const x = c as Record<string, unknown>;
    if (!x || typeof x.wrong !== "string" || !x.wrong.trim()) continue;
    corrections.push({
      wrong: x.wrong.trim().slice(0, 200),
      right: String(x.right ?? "").trim().slice(0, 200),
    });
  }
  const reorg: PatternReport["reorg"] = [];
  const ACTIONS = ["supersede", "merge", "linkfix", "archive"];
  for (const r of arr(o.reorg).slice(0, 4)) {
    const x = r as Record<string, unknown>;
    if (!x || typeof x.target !== "string" || !x.target.trim()) continue;
    const action = String(x.action ?? "");
    if (!ACTIONS.includes(action)) continue;
    reorg.push({
      action: action as PatternReport["reorg"][number]["action"],
      target: x.target.trim().slice(0, 160),
      reason: String(x.reason ?? "").trim().slice(0, 200),
    });
  }
  // All-empty is a VALID report ("nothing durable in the digest") -- only a
  // shapeless object is a parse failure.
  if (!Array.isArray(o.patterns) && !Array.isArray(o.corrections) && !Array.isArray(o.reorg)) return null;
  return { patterns, corrections, reorg };
}

// --- the AGENTS.md hot rail -------------------------------------------------

interface Section {
  before: string; // file start through the header line; or whole file when absent
  hasSection: boolean;
  header: string; // the existing header line (or "")
  body: string; // existing entries
  after: string; // the rest of the file after the entries
}

function splitSection(md: string): Section {
  const at = md.indexOf(HEADER_PREFIX);
  if (at < 0) return { before: md, hasSection: false, header: "", body: "", after: "" };
  const lineEnd = md.indexOf("\n", at);
  const header = md.slice(at, lineEnd < 0 ? md.length : lineEnd);
  const bodyStart = lineEnd < 0 ? md.length : lineEnd + 1;
  const next = md.indexOf("\n### ", bodyStart);
  if (next < 0) return { before: md.slice(0, bodyStart), hasSection: true, header, body: md.slice(bodyStart), after: "" };
  return {
    before: md.slice(0, bodyStart),
    hasSection: true,
    header,
    body: md.slice(bodyStart, next + 1),
    after: md.slice(next + 1), // starts at "### ..."
  };
}

function entryLines(body: string): string[] {
  return body.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("- ["));
}

function normalize(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

// --- runner -----------------------------------------------------------------

async function main(): Promise<void> {
  const file = process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : "";
  const reportFile = arg("report");
  if (!file && !reportFile) {
    console.error("usage: node .council/patterns.ts <digest-file> [--report json-file] [--tab id] [--dry-run] [--no-agents]");
    process.exit(2);
  }
  const dryRun = flag("dry-run");
  const noAgents = flag("no-agents");

  let digest = "";
  if (file) {
    digest = readFileSync(file, "utf8").replace(/^\uFEFF/, "").trim();
    if (digest.length < 80) {
      console.error("FATAL: digest too small (" + digest.length + " chars) -- refusing an empty run");
      process.exit(2);
    }
  }

  // Existing text -> the prompt's "already known" guard, so the recognizer
  // never re-emits a rule that already lives in AGENTS.md (standing rules,
  // style section, or previously learned patterns).
  const agentsExists = existsSync(AGENTS_PATH);
  const agentsText = agentsExists ? readFileSync(AGENTS_PATH, "utf8") : "";
  const knownPatterns = agentsText.trim() ? agentsText.trim().slice(0, 4000) : "(nothing learned yet)";

  let report: PatternReport;
  if (reportFile) {
    // Replay mode: run the write-half from a previously captured (or
    // salvaged) report. No Meta round -- the model already paid for it.
    const parsed = JSON.parse(readFileSync(reportFile, "utf8").replace(/^\uFEFF/, ""));
    const v = validateReport(parsed);
    if (!v) throw new Error("report file failed validation: " + reportFile);
    report = v;
    console.log("patterns: replay from " + reportFile + (dryRun ? " DRY-RUN" : ""));
  } else {
    // Meta tab: --tab wins, else the first live meta.ai page tab.
    // listTabs() already filters to type==="page" server-side and returns
    // {id, url, title, ws} -- there is no .type field here to check.
    let tabId = arg("tab", process.env.IO_META_TAB);
    if (!tabId) {
      const tabs = await listTabs();
      const meta = tabs.find((t) => t.url.includes("meta.ai"));
      if (!meta) {
        console.error("FATAL: no meta.ai tab found -- start Brave with --remote-debugging-port=9222");
        process.exit(2);
      }
      tabId = meta.id;
    }
    console.log("patterns: digest=" + digest.length + " chars tab=" + tabId + (dryRun ? " DRY-RUN" : ""));

    console.log("fresh chat...");
    await freshMetaChat(tabId, STALE_MARKER);
    console.log("fresh chat confirmed; asking the pattern recognizer...");

    const prompt = patternPrompt(digest, knownPatterns || "(nothing learned yet)");
    const askOnce = (): Promise<Parsed<PatternReport>> =>
      askJson<PatternReport>("metaChatCdp", prompt, validateReport, { tabId, timeoutMs: 180000 });
    let res = await askOnce();
    if (!res.ok && !/no JSON object|failed validation/.test(res.error)) {
      // Transport flake (render races) -- one retry, same rule as the council.
      console.log("transport retry (" + res.error.slice(0, 100) + ")");
      await new Promise((r) => setTimeout(r, 3000));
      res = await askOnce();
    }
    if (!res.ok) throw new Error("pattern recognizer FAIL: " + res.error.slice(0, 300));
    report = res.value;
  }
  console.log(
    "report: patterns=" + report.patterns.length +
      " corrections=" + report.corrections.length +
      " reorg=" + report.reorg.length,
  );

  const runId = "PAT-" + new Date().toISOString().replace(/\D/g, "").slice(0, 14);
  for (const r of report.reorg) {
    console.log("  reorg-hint: " + r.action + " " + r.target + " -- " + r.reason);
  }
  if (report.reorg.length) {
    console.log("  (reorg hints are logged for maintain.ts; patterns.ts never edits the vault)");
  }

  if (!report.patterns.length && !report.corrections.length) {
    appendFileSync(
      LOG,
      JSON.stringify({ ts: new Date().toISOString(), runId, file, report, agentsUpdated: false, claim: null }) + "\n",
      "utf8",
    );
    console.log("nothing durable in this digest -- no writes");
    return;
  }

  if (dryRun) {
    for (const p of report.patterns) console.log("  DRY pattern: " + p.statement + " (" + p.confidence.toFixed(2) + ")");
    for (const c of report.corrections) console.log("  DRY correction: " + c.wrong + " -> " + c.right);
    return;
  }

  // --- HOT RAIL: rewrite the Learned patterns section ---------------------
  const today = new Date().toISOString().slice(0, 10);
  const section = splitSection(agentsText);
  const existing = entryLines(section.body);
  const existingNorm = existing.map(normalize);
  const fresh: string[] = [];
  for (const p of report.patterns) {
    const n = normalize(p.statement);
    if (n && existingNorm.some((e) => e.includes(n) || n.includes(e))) continue;
    fresh.push("- [" + today + "] PATTERN: " + asciiFold(p.statement) + " (" + p.confidence.toFixed(2) + ")");
  }
  for (const c of report.corrections) {
    const n = normalize(c.wrong);
    if (n && existingNorm.some((e) => e.includes(n))) continue;
    fresh.push("- [" + today + "] CORRECTION: " + asciiFold(c.wrong) + " -> " + asciiFold(c.right));
  }

  let agentsUpdated = false;
  if (!noAgents && fresh.length) {
    const merged = [...existing, ...fresh].slice(-MAX_ENTRIES);
    let out: string;
    if (section.hasSection) {
      // section.before already ends with the header line + "\n".
      out = section.before + merged.join("\n") + "\n" + (section.after ? "\n" + section.after : "");
    } else {
      const header = HEADER_PREFIX + " (auto-maintained by .council/patterns.ts -- newest last)";
      const base = section.before.replace(/\s+$/, "");
      out = base + "\n\n" + header + "\n\n" + merged.join("\n") + "\n";
    }
    writeFileSync(AGENTS_PATH, out, "utf8");
    agentsUpdated = true;
    console.log("AGENTS.md hot rail: +" + fresh.length + " entries, " + merged.length + " total (cap " + MAX_ENTRIES + ")");
    for (const f of fresh) console.log("  " + f);
  } else if (!noAgents) {
    console.log("AGENTS.md hot rail: no new entries (all deduped)");
  }

  // --- DURABLE RAIL: one propose claim ------------------------------------
  const lines: string[] = [];
  for (const p of report.patterns.slice(0, 4)) lines.push("- PATTERN: " + asciiFold(p.statement));
  for (const c of report.corrections.slice(0, 3)) lines.push("- CORRECTION: " + asciiFold(c.wrong) + " -> " + asciiFold(c.right));
  const tail =
    "\n\n[pattern-run " + runId + ": " + report.patterns.length + " patterns, " +
    report.corrections.length + " corrections; receipts in .council/pattern-log.jsonl]";
  const claim = (lines.join("\n") + tail).slice(0, 1200);
  const title = asciiFold(
    "Pattern batch " + today + ": " + report.patterns.length + " patterns, " + report.corrections.length + " corrections",
  ).slice(0, 100);

  const staged = await callAdapter("propose", {
    title,
    claim,
    scope: "ObsidianVault",
    basis: "external-model",
    aliases: [],
    links: [],
    author: "pattern-recognizer",
  });
  if (!staged.ok) {
    appendFileSync(
      LOG,
      JSON.stringify({ ts: new Date().toISOString(), runId, file, report, agentsUpdated, claimError: staged.error }) + "\n",
      "utf8",
    );
    throw new Error("propose FAILED: " + String(staged.error).slice(0, 200));
  }
  const created = String((staged.result as { created?: string } | undefined)?.created || "?");
  appendFileSync(
    LOG,
    JSON.stringify({ ts: new Date().toISOString(), runId, file, report, agentsUpdated, claim: created }) + "\n",
    "utf8",
  );
  console.log("staged -> " + created);
  console.log("done: hotRail=" + agentsUpdated + " claim=1");
}

main().catch((e) => {
  console.error("FATAL " + String((e as Error).message));
  process.exit(1);
});
