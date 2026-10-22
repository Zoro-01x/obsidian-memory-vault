// .council/file.ts -- the only two ways council output leaves this directory:
//   1. a propose through vault-adapter.ps1 (THE door the MCP uses -- same
//      gates: path allowlist, dedupe, schema, atomic write, git commit).
//      Verdict/trust do NOT ride frontmatter (the MCP schema is closed); they
//      go inside the claim as a one-line stamp plus the full receipt below.
//   2. an append to .council/run-log.jsonl -- append-only, UTF-8 no BOM,
//      same pattern as .system/push-audit.jsonl.

import { spawn } from "node:child_process";
import { appendFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { ChunkOutcome, JudgeResult } from "./types.ts";

const VAULT_ROOT = fileURLToPath(new URL("../", import.meta.url));
const ADAPTER = VAULT_ROOT + ".system/vault-adapter.ps1";
const RUN_LOG = fileURLToPath(new URL("./run-log.jsonl", import.meta.url));

// ASCII fold for claims: the judge writes em-dashes and curly quotes, and
// PS 5.1's stdin mis-decodes them (mojibake in the filed note, first run).
export function asciiFold(s: string): string {
  return s
    .replace(/[\u2014\u2013]/g, "--")
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/\u2026/g, "...")
    .replace(/\u00A0/g, " ")
    .replace(/[^\x20-\x7E]/g, "");
}

// Build the claim text (judge body + stamp) within the propose 1200-char cap.
export function buildClaim(judge: JudgeResult, runId: string, chunkIndex: number): string {
  const tail =
    "\n\n[council " + runId + " chunk " + chunkIndex +
    ": verdict=" + judge.verdict +
    " confidence=" + judge.confidence.toFixed(2) +
    "; full receipts in .council/run-log.jsonl]";
  const room = 1200 - tail.length;
  const body = judge.claim ? asciiFold(judge.claim.body).slice(0, Math.max(200, room)) : "";
  return asciiFold(body) + asciiFold(tail);
}

export interface Filing {
  created: string;
  commit: string;
  warnings: string[];
}

export async function fileProposal(
  judge: JudgeResult,
  opts: { runId: string; chunkIndex: number; scope: string; author?: string },
): Promise<Filing> {
  if (!judge.claim) throw new Error("fileProposal: judge has no claim (verdict=" + judge.verdict + ")");
  const payload = {
    title: asciiFold(judge.claim.title),
    claim: buildClaim(judge, opts.runId, opts.chunkIndex),
    scope: opts.scope,
    basis: judge.claim.basis,
    aliases: [],
    links: [],
    author: opts.author ?? "council",
  };

  const out = await new Promise<{ stdout: string; stderr: string; code: number }>((res, rej) => {
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ADAPTER, "-Verb", "propose"],
      { cwd: VAULT_ROOT },
    );
    let stdout = "";
    let stderr = "";
    const to = setTimeout(() => {
      child.kill();
      rej(new Error("fileProposal: adapter timed out after 60s"));
    }, 60000);
    child.stdout.on("data", (d) => (stdout += String(d)));
    child.stderr.on("data", (d) => (stderr += String(d)));
    child.on("error", (e) => {
      clearTimeout(to);
      rej(e);
    });
    child.on("close", (code) => {
      clearTimeout(to);
      res({ stdout, stderr, code: code ?? 1 });
    });
    child.stdin.end(JSON.stringify(payload), "utf8");
  });

  const text = out.stdout.replace(/^\uFEFF/, "").trim();
  try {
    // The adapter wraps: {ok:true, result:{created, commit, warnings}}.
    // Unwrap without breaking on flat output (defensive, both shapes seen).
    const outer = JSON.parse(text) as {
      ok?: boolean;
      error?: string;
      result?: { created?: string; commit?: string; warnings?: string[]; error?: string };
      created?: string;
      commit?: string;
      warnings?: string[];
    };
    const j = outer.result ?? outer;
    if (outer.error || j.error || !j.created) {
      throw new Error(outer.error || j.error || ("no created field: " + text.slice(0, 200)));
    }
    return { created: j.created, commit: j.commit || "", warnings: j.warnings || [] };
  } catch (e) {
    throw new Error(
      "fileProposal: adapter output unparseable (code=" + out.code + "): " +
        String((e as Error).message).slice(0, 100) +
        " stdout=" + text.slice(0, 200) +
        " stderr=" + out.stderr.slice(0, 200),
    );
  }
}

// Generic adapter call for the maintenance/pattern lanes. Returns the FULL
// envelope ({ok, result|error, ...}) -- callers decide what counts as success
// so a refusal stays visible instead of becoming an exception with no receipt.
export async function callAdapter(
  verb: string,
  payload: Record<string, unknown>,
  timeoutMs = 60000,
): Promise<{ ok: boolean; result?: Record<string, unknown>; error?: string; errorType?: string; raw: string }> {
  const out = await new Promise<{ stdout: string; stderr: string; code: number }>((res, rej) => {
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ADAPTER, "-Verb", verb],
      { cwd: VAULT_ROOT },
    );
    let stdout = "";
    let stderr = "";
    const to = setTimeout(() => {
      child.kill();
      rej(new Error("callAdapter(" + verb + "): timed out after " + timeoutMs + "ms"));
    }, timeoutMs);
    child.stdout.on("data", (d) => (stdout += String(d)));
    child.stderr.on("data", (d) => (stderr += String(d)));
    child.on("error", (e) => {
      clearTimeout(to);
      rej(e);
    });
    child.on("close", (code) => {
      clearTimeout(to);
      res({ stdout, stderr, code: code ?? 1 });
    });
    child.stdin.end(JSON.stringify(payload), "utf8");
  });

  const text = out.stdout.replace(/^\uFEFF/, "").trim();
  if (!text) {
    throw new Error("callAdapter(" + verb + "): empty stdout (code=" + out.code + ") stderr=" + out.stderr.slice(0, 200));
  }
  try {
    const env = JSON.parse(text) as { ok?: boolean; result?: Record<string, unknown>; error?: string; errorType?: string };
    return { ok: env.ok === true, result: env.result, error: env.error, errorType: env.errorType, raw: text };
  } catch (e) {
    throw new Error(
      "callAdapter(" + verb + "): unparseable output (code=" + out.code + "): " +
        String((e as Error).message).slice(0, 100) + " stdout=" + text.slice(0, 200),
    );
  }
}

export function appendRunLog(entry: Record<string, unknown>): void {
  const line = JSON.stringify(entry) + "\n";
  appendFileSync(RUN_LOG, line, { encoding: "utf8" });
}

// Convenience: full per-chunk receipt shape for the run log.
export function logEntryForChunk(
  runId: string,
  engine: string,
  sourceFile: string,
  chunk: ChunkOutcome,
): Record<string, unknown> {
  return {
    ts: new Date().toISOString(),
    runId,
    engine,
    sourceFile,
    chunk: chunk.index,
    chars: chunk.chars,
    critics: chunk.critics.map((c) => ({
      critic: c.critic,
      call: c.call,
      ok: c.ok,
      ms: c.ms,
      notes: c.notes.slice(0, 300),
    })),
    judge: chunk.judge
      ? {
          verdict: chunk.judge.verdict,
          confidence: chunk.judge.confidence,
          reasons: chunk.judge.reasons,
          discard_reason: chunk.judge.discardReason,
          claim_title: chunk.judge.claim ? chunk.judge.claim.title : null,
          claim_basis: chunk.judge.claim ? chunk.judge.claim.basis : null,
        }
      : null,
    judgeError: chunk.judgeError,
    filed: chunk.filed,
    fileError: chunk.fileError,
  };
}

export function writeJson(path: string, data: unknown): void {
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
}
