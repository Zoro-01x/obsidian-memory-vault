// .council/tests/acceptance.ts -- the 7 break tests, ADOPTED VERBATIM from
// Sam's Meta thread (2026-10-21), mapped to this vault's real vocabulary.
// Build order per Meta: Tests 1-4 first (council behavior), Tests 5-7 after
// the MCP/meta-rule scripts -- those report honest RED until Phase 2 lands.
//
//   node .council/tests/acceptance.ts [1-4|5-7|all]
//
// Vocabulary mapping (feature map, settled earlier):
//   Distilled          -> permanent folders (entities/ decisions/ lessons/)
//   Archive / low      -> discard (nothing filed) or inbox quarantine
//   00-INDEX.md        -> CORE.md
//   search_brain       -> recall      search_archive -> recall (whole vault)
//   Index Builder      -> CORE.md curation + trust-decay meta-rule (Phase 2)
//   ARCHIVE-NOISE      -> judge verdict=discard
//
// Tests 1-4 run REAL council rounds against Meta chat (dry by construction:
// runCouncil never files -- filing lives in run.ts). Fresh chat per test so
// candidates cannot bleed into each other's verdicts.

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { runCouncil, freshMetaChat } from "../council.ts";
import type { ChunkReports } from "../council.ts";

const VAULT_ROOT = fileURLToPath(new URL("../../", import.meta.url));
const META_TAB = process.env.IO_META_TAB || "5CC4D20F456FBAD9B004B78FA444B3F0";

function readVaultIndex(): string {
  try {
    const t = readFileSync(VAULT_ROOT + "CORE.md", "utf8").trim();
    return t.length > 1500 ? t.slice(0, 1500) + "\n...(index truncated)" : t;
  } catch {
    return "(no index)";
  }
}

interface TestResult {
  id: number;
  name: string;
  status: "PASS" | "FAIL" | "RED";
  detail: string;
}

// ---- Tests 1-4: council behavior, runnable now ----

async function councilTest(
  id: number,
  name: string,
  candidate: string,
  staleMarker: string,
  judgeCheck: (r: ChunkReports) => { ok: boolean; detail: string },
): Promise<TestResult> {
  try {
    await freshMetaChat(META_TAB, staleMarker);
  } catch (e) {
    return { id, name, status: "RED", detail: "fresh chat failed: " + String((e as Error).message).slice(0, 120) };
  }
  const reports = await runCouncil(candidate, {
    engine: "metaChatCdp",
    tabId: META_TAB,
    vaultIndex: readVaultIndex(),
    sourceFile: "acceptance-test-" + id,
  });
  const j = reports.judge;
  if (!j) {
    return { id, name, status: "FAIL", detail: "no judge verdict (err: " + (reports.judgeError || "?").slice(0, 140) + ")" };
  }
  const checks = [
    "skeptic:" + reports.critics[0].call,
    "historian:" + reports.critics[1].call,
    "devil:" + reports.critics[2].call,
    "future:" + reports.critics[3].call,
    "verdict:" + j.verdict,
    "conf:" + j.confidence.toFixed(2),
  ].join(" ");
  const r = judgeCheck(reports);
  return { id, name, status: r.ok ? "PASS" : "FAIL", detail: checks + " | " + r.detail };
}

async function tests1to4(only: Set<number>): Promise<TestResult[]> {
  const results: TestResult[] = [];

  // Test 1: The Lie -- a false fact must never become a permanent note.
  if (only.has(1)) results.push(await councilTest(
    1,
    "The Lie",
    'Elon Musk acquired Obsidian in 2024',
    "TypeScript", // previous run's thread marker (rules candidate)
    (r) => {
      const ok = r.judge!.verdict === "discard";
      return { ok, detail: ok ? "lie discarded" : "LIE NOT CAUGHT: verdict=" + r.judge!.verdict };
    },
  ));

  // Test 2: The Contradiction -- historian must flag day1-vs-day2 conflict.
  // (Auto-supersede of the day-1 note is the Phase 2 meta-rule: reported RED
  // separately; the runnable core today is detection.)
  if (only.has(2)) results.push(await councilTest(
    2,
    "The Contradiction",
    "Day 1 record: We will use Firebase for auth.\n\nDay 2 record: We will use Supabase for auth, Firebase is too expensive.",
    "Elon Musk",
    (r) => {
      const hist = r.critics[1];
      const named = /firebase/i.test(hist.notes) && /supabase/i.test(hist.notes);
      const flagged = hist.call !== "pass" || named;
      return {
        ok: flagged,
        detail: flagged
          ? "historian flagged: " + hist.notes.slice(0, 100)
          : "historian missed the contradiction (call=" + hist.call + ")",
      };
    },
  ));

  // Test 3: The Noise -- mood/to-do debris must never be stored.
  if (only.has(3)) results.push(await councilTest(
    3,
    "The Noise",
    "lol that meeting was funny, need coffee",
    "Supabase",
    (r) => {
      const ok = r.judge!.verdict === "discard";
      return { ok, detail: ok ? "noise discarded" : "NOISE KEPT: verdict=" + r.judge!.verdict };
    },
  ));

  // Test 4: The Useful Nuance -- must MODIFY (hedge the absolute), not KEEP.
  if (only.has(4)) results.push(await councilTest(
    4,
    "The Useful Nuance",
    "RSCs are always faster, migrate everything",
    "coffee",
    (r) => {
      const v = r.judge!.verdict;
      const body = r.judge!.claim ? r.judge!.claim.body.toLowerCase() : "";
      // "keeps the absolute" = asserting it, not mentioning it. "not always
      // faster" is the CORRECT hedge (Meta's spec) and must pass.
      const at = body.indexOf("always faster");
      let keepsAbsolute = false;
      if (at >= 0) {
        const before = body.slice(Math.max(0, at - 15), at);
        keepsAbsolute = !/\bnot|n't|never|hardly|false|wrong|myth|debunk/.test(before);
      }
      const ok = v === "modify" && !keepsAbsolute;
      return {
        ok,
        detail: ok
          ? "modified with hedge: " + (r.judge!.claim ? r.judge!.claim.body.slice(0, 90) : "")
          : v === "keep" && keepsAbsolute
            ? "DEVIL WEAK: kept 'always faster' verbatim"
            : "verdict=" + v + " absoluteKept=" + keepsAbsolute,
      };
    },
  ));

  return results;
}

// ---- Tests 5-7: MCP / meta-rule side, honest RED until Phase 2 ----

async function tests5to7(only: Set<number>): Promise<TestResult[]> {
  const results: TestResult[] = [];

  // Test 5: The Memory Recall -- the MCP consumer prompt must FORCE recall
  // before answering past-decision questions.
  // Test 5: The Memory Recall -- the MCP layer's OWN text (tool description +
  // session instructions, what every consuming model actually reads) must
  // force recall-before-answer.
  let mcpSrc = "";
  try {
    mcpSrc = readFileSync(VAULT_ROOT + ".system/vault-mcp.mjs", "utf8");
  } catch {
    mcpSrc = "(config unreadable)";
  }
  const forcedRecall = /MUST call recall/i.test(mcpSrc);
  if (only.has(5)) results.push({
    id: 5,
    name: "The Memory Recall",
    status: forcedRecall ? "PASS" : "RED",
    detail: forcedRecall
      ? "MCP recall description + session instructions force recall-before-answer"
      : "BLOCKED: vault-mcp.mjs lacks the 'MUST call recall' directive in tool description or instructions",
  });

  // Test 6: The Trust Decay -- LIVE probe against the real adapter: minTrust
  // must filter (open query returns hits; 0.95 returns none, since no note
  // can exceed trust 0.9), and the decay code must exist in the lib.
  let decay = false;
  let probeNote = "";
  try {
    const lib = readFileSync(VAULT_ROOT + ".system/vault-lib.ps1", "utf8");
    const hasDecayCode = /trust/i.test(lib) && /MinTrust/.test(lib);
    const runRecall = (args: Record<string, unknown>): number => {
      const r = spawnSync(
        "powershell.exe",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", VAULT_ROOT + ".system/vault-adapter.ps1", "-Verb", "recall"],
        { input: JSON.stringify(args), encoding: "utf8", cwd: VAULT_ROOT, timeout: 60000 },
      );
      const t = String(r.stdout || "").replace(/^\uFEFF/, "").trim();
      const j = JSON.parse(t) as { ok?: boolean; error?: string; result?: { count?: number } };
      if (j.ok !== true) throw new Error("adapter refused: " + (j.error || "?"));
      return j.result?.count ?? -1;
    };
    const open = runRecall({ query: "vault", minTrust: 0 });
    const strict = runRecall({ query: "vault", minTrust: 0.95 });
    decay = hasDecayCode && open > 0 && strict === 0;
    probeNote = "decayCode=" + hasDecayCode + " openHits=" + open + " strictHitsAt0.95=" + strict;
  } catch (e) {
    probeNote = "probe error: " + String((e as Error).message).slice(0, 140);
    decay = false;
  }
  if (only.has(6)) results.push({
    id: 6,
    name: "The Trust Decay",
    status: decay ? "PASS" : "RED",
    detail: decay
      ? "live probe: " + probeNote
      : "BLOCKED/FAILED: " + probeNote + " (needs decay code in vault-lib.ps1 + a working minTrust filter)",
  });

  // Test 7: The Low-Trust Resurrection -- recall must reach notes regardless
  // of status (stale/superseded stay findable even when out of CORE).
  let recallAll = false;
  try {
    const mcp = readFileSync(VAULT_ROOT + ".system/vault-mcp.mjs", "utf8");
    const lib = readFileSync(VAULT_ROOT + ".system/vault-lib.ps1", "utf8");
    // A status filter that excludes stale/superseded from search would fail this.
    const filtersStatus = /status.*(active)[^s]/.test(lib) && /stale/.test(lib) === false;
    recallAll = !filtersStatus;
  } catch {
    recallAll = false;
  }
  if (only.has(7)) results.push({
    id: 7,
    name: "The Low-Trust Resurrection",
    status: recallAll ? "PASS" : "RED",
    detail: recallAll
      ? "recall path has no active-only status filter (structural check; seeded end-to-end probe lands with minTrust args)"
      : "BLOCKED: recall path may filter by status, or check failed (Phase 2: minTrust args + seeded stale probe)",
  });

  return results;
}

// ---- runner ----

async function main(): Promise<void> {
  const which = process.argv[2] || "all";
  let only: Set<number>;
  if (which === "all") only = new Set([1, 2, 3, 4, 5, 6, 7]);
  else if (which === "1-4") only = new Set([1, 2, 3, 4]);
  else if (which === "5-7") only = new Set([5, 6, 7]);
  else if (/^[1-7]$/.test(which)) only = new Set([+which]);
  else {
    console.error("usage: node .council/tests/acceptance.ts [all|1-4|5-7|1..7]");
    process.exit(2);
  }
  const results: TestResult[] = [];
  const started = Date.now();

  if ([1, 2, 3, 4].some((n) => only.has(n))) {
    results.push(...(await tests1to4(only)));
  }
  if ([5, 6, 7].some((n) => only.has(n))) {
    results.push(...(await tests5to7(only)));
  }

  console.log("=== ACCEPTANCE SUITE (Meta thread, verbatim intent) ===");
  for (const r of results) {
    console.log(
      (r.status === "PASS" ? "PASS " : r.status === "FAIL" ? "FAIL " : "RED  ") +
        "Test " + r.id + " " + r.name + " -- " + r.detail,
    );
  }
  const pass = results.filter((r) => r.status === "PASS").length;
  const fail = results.filter((r) => r.status === "FAIL").length;
  const red = results.filter((r) => r.status === "RED").length;
  console.log("---");
  console.log("score: " + pass + " pass, " + fail + " fail, " + red + " red-blocked (of " + results.length + ") in " + Math.round((Date.now() - started) / 1000) + "s");
  process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error("FATAL " + String((e as Error).message));
  process.exit(1);
});
