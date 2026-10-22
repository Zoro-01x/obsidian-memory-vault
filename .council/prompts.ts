// .council/prompts.ts -- the four attackers and the judge. ASCII only.
// Critics answer in a tiny fixed format (receipts); the judge answers strict
// JSON (parse-or-loud-reject lives in council.ts). The judge always receives
// critic RAW text, so critic format drift never blocks a run.

import type { CriticId } from "./types.ts";

const MAX_CRITIC_WORDS = 90;

const ROLE: Record<CriticId, string> = {
  skeptic:
    "You are THE SKEPTIC. Test this candidate against reality: dates, named products, causal claims, statistics. " +
    "If you have web research available, use it; if not, write research-unavailable and reason from what you know. " +
    "Flag anything false, outdated, or unverifiable. Do not nitpick wording.",
  historian:
    "You are THE HISTORIAN. Compare this candidate against the vault index below: does an existing note contradict it, " +
    "duplicate it, or already supersede it? Name the clashing note by title if there is one. If the index is empty or silent, say index-silent.",
  devil:
    "You are THE DEVIL'S ADVOCATE. Assume this candidate is wrong. Build the strongest honest case against storing it. " +
    "No strawmen, no sarcasm. If you cannot find a real case, write no-strong-case.",
  future:
    "You are THE FUTURE SELF, six months from now. Will this candidate help, mislead, or pollute? Is it a durable fact, " +
    "preference, or decision, or is it mood/noise/to-do debris? One direct call.",
};

export function criticPrompt(
  critic: CriticId,
  candidate: string,
  vaultIndex: string,
): string {
  // No source filename here on purpose: reviewers saw the staging path
  // (phase1-transcript.txt) and called the candidate "debug debris" -- they
  // must judge the CONTENT, not the temp file it arrived in. Basis/source is
  // the judge's job.
  return (
    "PRIVATE VAULT REVIEW -- you are one of four reviewers. Answer in EXACTLY this format, first line first:\n" +
    "verdict: pass|concern|fail\n" +
    "notes: <at most " + MAX_CRITIC_WORDS + " words>\n\n" +
    ROLE[critic] +
    "\n\nCANDIDATE:\n---\n" +
    candidate +
    "\n---\n\nVAULT INDEX (existing notes):\n---\n" +
    vaultIndex +
    "\n---"
  );
}

export function judgePrompt(
  candidate: string,
  criticBlocks: Array<{ critic: CriticId; raw: string }>,
  sourceFile: string,
): string {
  const reports = criticBlocks
    .map((b) => "[" + b.critic + "]\n" + b.raw)
    .join("\n\n");
  return (
    "PRIVATE VAULT JUDGE. You receive one candidate memory and the four reviewers' reports. Decide whether the candidate " +
    "enters the vault. Reply with ONLY one JSON object, no prose, no code fences:\n" +
    '{"verdict":"keep|modify|discard","confidence":0.0,"reasons":["critic: one line each"],"claim":{"title":"...","basis":"observed|user-stated|inferred|external-model","body":"..."},"discard_reason":""}\n\n' +
    "Rules:\n" +
    "- claim is required unless verdict is discard; discard requires discard_reason.\n" +
    "- verdict choice: discard ONLY when there is no durable value at all (noise, mood, pure fabrication with no " +
    "salvageable kernel). When a true or useful insight sits inside a wrong, outdated, or overstated framing, choose " +
    "modify and write the corrected claim -- losing a real insight to over-correction is a failure, same as storing a lie.\n" +
    "- claim.body is ONE durable note (max 900 chars), written as the settled statement a future agent should read, " +
    "folding in every valid critic concern (a modify fixes the candidate; a keep stores it as-is).\n" +
    "- basis: user-stated when Sam said it; external-model when an AI produced it; observed only when verified firsthand; inferred when you concluded it.\n" +
    "- reasons: one line per reviewer with their key point, even when you disagree.\n" +
    "- confidence is 0.0-1.0: how well this survived the attack, not how true you feel.\n\n" +
    "REVIEWERS:\n" + reports + "\n\nCANDIDATE (source file: " + sourceFile + "):\n---\n" + candidate + "\n---"
  );
}

// --- pattern recognition (Sam-approved 2026-10-22) ---------------------------
// Meta's second job: turn what happened in the working chat into durable
// patterns, corrections and maintenance hints. Same fresh-chat lane and
// strict-JSON discipline as the judge; ASCII only.

export interface PatternEntry {
  statement: string;
  evidence: string;
  confidence: number;
}
export interface CorrectionEntry {
  wrong: string;
  right: string;
}
export interface ReorgEntry {
  action: "supersede" | "merge" | "linkfix" | "archive";
  target: string;
  reason: string;
}
export interface PatternReport {
  patterns: PatternEntry[];
  corrections: CorrectionEntry[];
  reorg: ReorgEntry[];
}

export function patternPrompt(digest: string, knownPatterns: string): string {
  return (
    "PRIVATE VAULT PATTERN RECOGNIZER. You receive a digest of what happened in the user's working chat and the pattern list already learned. Reply with ONLY one JSON object, no prose, no code fences:\n" +
    '{"patterns":[{"statement":"one durable behavior or style pattern","evidence":"what in the digest shows it","confidence":0.0}],"corrections":[{"wrong":"assumption or behavior that proved wrong","right":"the corrected form"}],"reorg":[{"action":"supersede|merge|linkfix|archive","target":"note or area","reason":"why"}]}\n\n' +
    "Rules:\n" +
    "- patterns: only NEW durable observations about how the user works or how the agent must behave; never repeat an already-learned pattern; max 5; each statement max 160 chars, specific and actionable.\n" +
    "- corrections: mistakes (honest errors, misleading assumptions) from this digest that must never repeat; max 4; each max 160 chars.\n" +
    "- reorg: only concrete maintenance actions the digest itself justifies; max 4; empty array when none.\n" +
    "- confidence is 0.0-1.0. If nothing durable is in the digest, return all three arrays empty -- do not invent patterns.\n\n" +
    "ALREADY LEARNED (do not repeat):\n---\n" + knownPatterns + "\n---\n\n" +
    "CHAT DIGEST:\n---\n" + digest + "\n---"
  );
}
