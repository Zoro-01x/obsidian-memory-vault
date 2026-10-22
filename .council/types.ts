// .council/types.ts -- the Council's contracts. Erasable TS only.

export type Verdict = "keep" | "modify" | "discard";
export type CriticId = "skeptic" | "historian" | "devil" | "future";
export type CriticCall = "pass" | "concern" | "fail";
export type Basis = "observed" | "user-stated" | "inferred" | "external-model";

export interface CriticReport {
  critic: CriticId;
  call: CriticCall | "unparsed";
  notes: string; // parsed notes, or raw tail when unparsed (judge still saw raw)
  raw: string;
  ms: number;
  ok: boolean; // transport+reply succeeded (format drift is ok:false with raw kept)
}

export interface CouncilClaim {
  title: string;
  basis: Basis;
  body: string;
}

export interface JudgeResult {
  verdict: Verdict;
  confidence: number;
  reasons: string[];
  claim: CouncilClaim | null;
  discardReason: string;
  ms: number;
}

export interface ChunkOutcome {
  index: number;
  chars: number;
  critics: CriticReport[];
  judge: JudgeResult | null;
  judgeError: string | null;
  filed: { created: string; commit: string; warnings: string[] } | null;
  fileError: string | null;
}
