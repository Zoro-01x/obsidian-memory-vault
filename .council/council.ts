// .council/council.ts -- runs one chunk through the four attackers then the
// judge. The chat engine is a single tab, so rounds are SEQUENTIAL by design
// (a later API engine restores parallel fan-out behind the same interface).
// Fresh chat per run: navigate the tab to meta.ai and assert the old thread
// is gone before the first prompt -- never reason over a polluted thread.

import { listTabs, connect, sleep } from "../.io/util.ts";
import { ask, askJson } from "../.io/ask.ts";
import { FORBIDDEN_PROMPT_IDS, extractConversation } from "../.io/adapters.ts";
import type { Parsed } from "../.io/types.ts";
import { criticPrompt, judgePrompt } from "./prompts.ts";
import type {
  CriticCall,
  CriticId,
  CriticReport,
  JudgeResult,
} from "./types.ts";

const CRITICS: CriticId[] = ["skeptic", "historian", "devil", "future"];

const CALL_RE = /verdict:\s*(pass|concern|fail)\b/i;

function parseCritic(raw: string): { call: CriticCall | "unparsed"; notes: string } {
  const m = raw.match(CALL_RE);
  const noteAt = raw.search(/notes:\s*/i);
  const notes =
    noteAt >= 0 ? raw.slice(noteAt).replace(/notes:\s*/i, "").trim() : raw.trim();
  if (!m) return { call: "unparsed", notes };
  return { call: m[1].toLowerCase() as CriticCall, notes };
}

// Navigate a meta tab to a brand-new chat and PROVE the previous thread is
// gone (staleMarker must vanish) before returning. Failure is loud: running
// a council over leftover conversation would poison every verdict.
export async function freshMetaChat(tabId: string, staleMarker: string): Promise<void> {
  const tabs = await listTabs();
  const tab = tabs.find((t) => t.id === tabId);
  if (!tab) throw new Error("freshMetaChat: tab not found: " + tabId);
  if (!tab.url.includes("meta.ai")) throw new Error("freshMetaChat: not a meta.ai tab: " + tab.url);
  for (const id of FORBIDDEN_PROMPT_IDS) {
    if (tab.url.includes(id)) throw new Error("freshMetaChat: refusing -- that tab is the Hindsight chat");
  }
  const cdp = await connect(tab.ws);
  try {
    await cdp.send("Page.navigate", { url: "https://www.meta.ai/" });
    for (let i = 0; i < 20; i++) {
      await sleep(750);
      const body = (await cdp.evalJs("document.body.innerText")) || "";
      const composer = body.includes("Ask Meta AI");
      // Marker check is scoped to the CONVERSATION region: the sidebar keeps
      // old chats' history titles (Meta generates titles containing marker
      // words), and those must not block the freshness assert.
      const region = extractConversation(body, "metaAi");
      if (composer && !region.includes(staleMarker)) return;
    }
    const body = (await cdp.evalJs("document.body.innerText")) || "";
    const region = extractConversation(body, "metaAi");
    throw new Error(
      "freshMetaChat: new-chat not confirmed (composerReady=" +
        body.includes("Ask Meta AI") +
        ", staleMarkerStillPresentInConversation=" +
        region.includes(staleMarker) +
        ")",
    );
  } finally {
    cdp.close();
  }
}

export interface CouncilContext {
  engine: "metaChatCdp" | "manual" | "nimApi";
  tabId?: string; // required for metaChatCdp
  vaultIndex: string;
  sourceFile: string;
  timeoutMs?: number;
}

export interface ChunkReports {
  critics: CriticReport[];
  judge: JudgeResult | null;
  judgeError: string | null;
}

export async function runCouncil(candidate: string, ctx: CouncilContext): Promise<ChunkReports> {
  const critics: CriticReport[] = [];
  const rawBlocks: Array<{ critic: CriticId; raw: string }> = [];

  for (const critic of CRITICS) {
    const prompt = criticPrompt(critic, candidate, ctx.vaultIndex);
    // One transport retry: the current Meta variant flakes ~1/6 sends on
    // render races (observed evening 2026-10-21) -- a flake must not fail a
    // whole council round. Parse failures are not retried here.
    const askOpts = { tabId: ctx.tabId, timeoutMs: ctx.timeoutMs ?? 180000 };
    try {
      let r;
      try {
        r = await ask(ctx.engine, prompt, askOpts);
      } catch (e1) {
        console.log("  critic " + critic + ": transport retry (" + String((e1 as Error).message).slice(0, 90) + ")");
        await new Promise((res) => setTimeout(res, 3000));
        r = await ask(ctx.engine, prompt, askOpts);
      }
      const { call, notes } = parseCritic(r.reply);
      critics.push({ critic, call, notes, raw: r.reply, ms: r.ms, ok: true });
      rawBlocks.push({ critic, raw: r.reply });
      console.log(
        "  critic " + critic + ": " + call + " ms=" + r.ms + " notes=" + JSON.stringify(notes.slice(0, 90)),
      );
    } catch (e) {
      const msg = String((e as Error).message);
      critics.push({ critic, call: "unparsed", notes: "TRANSPORT ERROR: " + msg, raw: "", ms: 0, ok: false });
      rawBlocks.push({ critic, raw: "[no reply: " + msg + "]" });
      console.log("  critic " + critic + ": TRANSPORT FAIL " + msg.slice(0, 120));
    }
  }

  const jprompt = judgePrompt(candidate, rawBlocks, ctx.sourceFile);
  const askJudge = (): Promise<Parsed<JudgeResult>> =>
    askJson<JudgeResult>(
      ctx.engine,
      jprompt,
      (v): JudgeResult | null => {
        const o = v as Record<string, unknown>;
        const verdict = o.verdict;
        if (verdict !== "keep" && verdict !== "modify" && verdict !== "discard") return null;
        const confidence = typeof o.confidence === "number" ? o.confidence : NaN;
        if (!(confidence >= 0 && confidence <= 1)) return null;
        const claim = o.claim as { title?: unknown; basis?: unknown; body?: unknown } | undefined;
        let claimOut = null;
        if (verdict !== "discard") {
          if (!claim || typeof claim.body !== "string" || !claim.body.trim()) return null;
          const basis =
            claim.basis === "observed" || claim.basis === "user-stated" ||
            claim.basis === "inferred" || claim.basis === "external-model"
              ? claim.basis
              : "external-model";
          claimOut = {
            title: (typeof claim.title === "string" && claim.title.trim() ? claim.title : claim.body).slice(0, 100),
            basis,
            body: claim.body.slice(0, 900),
          };
        }
        return {
          verdict,
          confidence,
          reasons: Array.isArray(o.reasons) ? o.reasons.map((x) => String(x)).slice(0, 8) : [],
          claim: claimOut,
          discardReason: typeof o.discard_reason === "string" ? o.discard_reason : "",
          ms: 0,
        };
      },
      { tabId: ctx.tabId, timeoutMs: ctx.timeoutMs ?? 180000 },
    );
  try {
    // One transport retry (render races flake ~1/6 sends on the current Meta
    // variant); parse/validation failures already get askJson's own retry.
    let res = await askJudge();
    if (!res.ok && !/no JSON object|failed validation/.test(res.error)) {
      console.log("  judge: transport retry (" + res.error.slice(0, 100) + ")");
      await new Promise((r) => setTimeout(r, 3000));
      res = await askJudge();
    }
    if (!res.ok) {
      console.log("  judge: FAIL " + res.error.slice(0, 200));
      return { critics, judge: null, judgeError: res.error };
    }
    const judge = { ...res.value, ms: res.ms };
    console.log(
      "  judge: " + judge.verdict + " conf=" + judge.confidence.toFixed(2) + " ms=" + res.ms +
        (judge.claim ? " claim=" + JSON.stringify(judge.claim.title.slice(0, 60)) : " reason=" + judge.discardReason.slice(0, 80)),
    );
    return { critics, judge, judgeError: null };
  } catch (e) {
    const msg = String((e as Error).message);
    console.log("  judge: THREW " + msg.slice(0, 160));
    return { critics, judge: null, judgeError: msg };
  }
}
