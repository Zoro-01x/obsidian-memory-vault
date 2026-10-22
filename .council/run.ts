// .council/run.ts -- hand-triggered Phase 1 runner.
//   node .council/run.ts <transcript-file> [options]
// Options:
//   --tab <id>           meta tab (required default: IO_META_TAB env)
//   --engine <e>         metaChatCdp (default) | manual | nimApi
//   --scope <s>          propose scope            (default "ObsidianVault")
//   --stale-marker <s>   old-thread marker that must vanish on fresh chat
//   --keep-chat          skip the fresh-chat navigation (debug)
//   --max-chunks <n>     process at most n chunks (budget control)
//   --dry-run            run the council + log, do not propose
//
// Per chunk: 4 critics (sequential on one chat tab) -> judge JSON -> either a
// propose through vault-adapter (gates intact) or a discard, both recorded in
// .council/run-log.jsonl.

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { runCouncil, freshMetaChat } from "./council.ts";
import { fileProposal, appendRunLog, logEntryForChunk } from "./file.ts";
import type { ChunkOutcome } from "./types.ts";

const VAULT_ROOT = fileURLToPath(new URL("../", import.meta.url));
const CHUNK_MAX = 1400;

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
function flag(name: string): boolean {
  return process.argv.includes("--" + name);
}

// Split on blank lines first; oversize paragraphs split on sentence ends;
// anything still oversize hard-splits. Bounded, deterministic, no deps.
export function chunkText(text: string, max = CHUNK_MAX): string[] {
  const paras = text.replace(/\r\n/g, "\n").split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  const pieces: string[] = [];
  for (const p of paras) {
    if (p.length <= max) {
      pieces.push(p);
      continue;
    }
    const sentences = p.split(/(?<=[.!?])\s+/);
    let buf = "";
    for (const s of sentences) {
      if ((buf + " " + s).trim().length > max) {
        if (buf) pieces.push(buf.trim());
        if (s.length > max) {
          for (let i = 0; i < s.length; i += max) pieces.push(s.slice(i, i + max));
          buf = "";
        } else {
          buf = s;
        }
      } else {
        buf = (buf ? buf + " " : "") + s;
      }
    }
    if (buf.trim()) pieces.push(buf.trim());
  }
  // Merge tiny trailing pieces into the previous chunk where they fit.
  const merged: string[] = [];
  for (const piece of pieces) {
    const prev = merged[merged.length - 1];
    if (prev && prev.length + piece.length + 2 <= max) merged[merged.length - 1] = prev + "\n\n" + piece;
    else merged.push(piece);
  }
  return merged;
}

function readVaultIndex(): string {
  const p = VAULT_ROOT + "CORE.md";
  if (!existsSync(p)) return "(no vault index: CORE.md missing)";
  const t = readFileSync(p, "utf8").trim();
  return t.length > 1500 ? t.slice(0, 1500) + "\n...(index truncated)" : t;
}

async function main(): Promise<void> {
  const file = process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : "";
  if (!file) {
    console.error('usage: node .council/run.ts <transcript-file> [--tab id] [--engine e] [--scope s] [--stale-marker s] [--keep-chat] [--max-chunks n] [--dry-run]');
    process.exit(2);
  }
  const engine = (arg("engine", "metaChatCdp") || "metaChatCdp") as "metaChatCdp" | "manual" | "nimApi";
  const tabId = arg("tab", process.env.IO_META_TAB || "5CC4D20F456FBAD9B004B78FA444B3F0");
  const scope = arg("scope", "ObsidianVault") || "ObsidianVault";
  const staleMarker = arg("stale-marker", "pre-push") || "pre-push";
  const maxChunks = +(arg("max-chunks", "0") || 0);
  const dryRun = flag("dry-run");

  const source = readFileSync(file, "utf8");
  if (source.trim().length < 100) {
    console.error("FATAL: transcript too small (" + source.trim().length + " chars) -- refusing an empty run");
    process.exit(2);
  }
  const chunks = chunkText(source.trim(), CHUNK_MAX);
  console.log(
    "run: file=" + file + " chars=" + source.trim().length + " chunks=" + chunks.length +
      " engine=" + engine + (maxChunks ? " maxChunks=" + maxChunks : "") + (dryRun ? " DRY-RUN" : ""),
  );

  const runId =
    new Date().toISOString().replace(/\D/g, "").slice(0, 14) + "-" +
    Math.random().toString(36).slice(2, 6);
  const vaultIndex = readVaultIndex();

  if (engine === "metaChatCdp" && !flag("keep-chat")) {
    if (!tabId) {
      console.error("FATAL: metaChatCdp needs --tab or IO_META_TAB");
      process.exit(2);
    }
    console.log("fresh chat on tab " + tabId + " (stale marker: " + JSON.stringify(staleMarker) + ")...");
    await freshMetaChat(tabId, staleMarker);
    console.log("fresh chat confirmed");
  }

  const started = Date.now();
  const outcomes: ChunkOutcome[] = [];
  const todo = maxChunks > 0 ? chunks.slice(0, maxChunks) : chunks;

  for (let i = 0; i < todo.length; i++) {
    const chunk = todo[i];
    console.log("chunk " + (i + 1) + "/" + todo.length + " (" + chunk.length + " chars)");
    const reports = await runCouncil(chunk, {
      engine,
      tabId: engine === "metaChatCdp" ? tabId : undefined,
      vaultIndex,
      sourceFile: file,
    });

    let filed: ChunkOutcome["filed"] = null;
    let fileError: string | null = null;
    const judge = reports.judge;
    if (judge && judge.claim && !dryRun) {
      try {
        filed = await fileProposal(judge, { runId, chunkIndex: i + 1, scope });
        console.log("  filed -> " + filed.created + " commit=" + filed.commit.slice(0, 8));
        if (filed.warnings.length) console.log("  warnings: " + filed.warnings.join(" | "));
      } catch (e) {
        fileError = String((e as Error).message);
        console.log("  FILE FAIL: " + fileError.slice(0, 200));
      }
    } else if (judge && judge.claim && dryRun) {
      console.log("  dry-run: proposal NOT filed (claim kept in log)");
    } else if (judge) {
      console.log("  discard: nothing filed (" + (judge.discardReason || "no reason given").slice(0, 120) + ")");
    }

    const outcome: ChunkOutcome = {
      index: i + 1,
      chars: chunk.length,
      critics: reports.critics,
      judge,
      judgeError: reports.judgeError,
      filed,
      fileError,
    };
    outcomes.push(outcome);
    appendRunLog(logEntryForChunk(runId, engine, file, outcome));
  }

  const okCritic = outcomes.flatMap((o) => o.critics).filter((c) => c.ok).length;
  const totalCritic = outcomes.flatMap((o) => o.critics).length;
  const keeps = outcomes.filter((o) => o.judge && o.judge.verdict !== "discard").length;
  const filedOk = outcomes.filter((o) => o.filed).length;
  const errs = outcomes.filter((o) => o.judgeError || o.fileError).length;
  console.log("---");
  console.log(
    "run " + runId + ": chunks=" + outcomes.length + "/" + chunks.length +
      " critics=" + okCritic + "/" + totalCritic +
      " keepOrModify=" + keeps + " filed=" + filedOk +
      (dryRun ? " (dry)" : "") + " errors=" + errs +
      " totalMs=" + (Date.now() - started),
  );
  process.exit(errs === 0 && okCritic === totalCritic && outcomes.length > 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("FATAL " + String((e as Error).message));
  process.exit(1);
});
