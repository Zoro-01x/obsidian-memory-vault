// .io/tests/io-suite.ts -- Phase 0 done-criterion runner.
//   node .io/tests/io-suite.ts nim [rounds]    structured API rounds
//   node .io/tests/io-suite.ts meta [rounds]   meta.ai chat rounds (CDP)
//   node .io/tests/io-suite.ts read            transcript extraction sanity
// PASS = every round parsed+validated with zero manual fixes.

import { askJson } from "../ask.ts";
import { readChat } from "../readChat.ts";
import type { Site } from "../types.ts";

const [cmd, roundsArg] = process.argv.slice(2);
const ROUNDS = +(roundsArg || 10);

const TABS: Record<Site, string> = {
  metaAi: process.env.IO_META_TAB || "5CC4D20F456FBAD9B004B78FA444B3F0",
  chatgpt: process.env.IO_GPT_TAB || "9E29A3A660133A9EB8D371E99A1B5C7E",
  claude: process.env.IO_CLAUDE_TAB || "4507071B93B45D97FBBAC181102F152F",
};

type RoundShape = { round: number };
const validateRound = (expected: number) => (v: unknown): RoundShape | null => {
  const o = v as { round?: unknown };
  return o && typeof o.round === "number" && o.round === expected ? { round: o.round } : null;
};

async function runRounds(engine: "nimApi" | "metaChatCdp"): Promise<void> {
  let pass = 0;
  const problems: string[] = [];
  for (let n = 1; n <= ROUNDS; n++) {
    const prompt = 'Reply with ONLY this JSON object and nothing else: {"round":' + n + "}";
    try {
      const res = await askJson<RoundShape>(engine, prompt, validateRound(n), {
        tabId: engine === "metaChatCdp" ? TABS.metaAi : undefined,
        timeoutMs: engine === "metaChatCdp" ? 180000 : 60000,
      });
      if (res.ok) {
        pass++;
        console.log("round " + n + "/" + ROUNDS + ": PASS  ms=" + res.ms);
      } else {
        problems.push("round " + n + ": " + res.error);
        console.log("round " + n + "/" + ROUNDS + ": FAIL  ms=" + res.ms + "  " + res.error.slice(0, 160));
      }
    } catch (e) {
      problems.push("round " + n + " THREW: " + String((e as Error).message));
      console.log("round " + n + "/" + ROUNDS + ": THREW " + String((e as Error).message).slice(0, 160));
    }
  }
  console.log("---");
  console.log(engine + ": " + pass + "/" + ROUNDS + " (fumbles=" + problems.length + ")");
  process.exit(pass === ROUNDS ? 0 : 1);
}

async function runRead(): Promise<void> {
  const checks: Array<{ site: Site; ok: boolean; note: string }> = [];
  for (const site of ["metaAi", "chatgpt", "claude"] as Site[]) {
    try {
      const r = await readChat(site, TABS[site]);
      const hasSidebar = r.text.includes("Pinned") || r.text.includes("Ctrl+Shift+O");
      const hasConsult = r.text.includes("pre-push");
      const ok = r.text.length > 500 && !hasSidebar && hasConsult;
      checks.push({
        site,
        ok,
        note:
          "len=" + r.text.length + " ms=" + r.ms +
          " sidebarStripped=" + !hasSidebar +
          " consultPresent=" + hasConsult +
          " head=" + JSON.stringify(r.text.slice(0, 60)),
      });
    } catch (e) {
      checks.push({ site, ok: false, note: "THREW " + String((e as Error).message) });
    }
  }
  for (const c of checks) console.log((c.ok ? "PASS " : "FAIL ") + c.site + "  " + c.note);
  const all = checks.every((c) => c.ok);
  console.log("---");
  console.log("read: " + checks.filter((c) => c.ok).length + "/" + checks.length);
  process.exit(all ? 0 : 1);
}

if (cmd === "nim") {
  runRounds("nimApi").catch((e) => { console.error("FATAL " + String(e)); process.exit(1); });
} else if (cmd === "meta") {
  runRounds("metaChatCdp").catch((e) => { console.error("FATAL " + String(e)); process.exit(1); });
} else if (cmd === "read") {
  runRead().catch((e) => { console.error("FATAL " + String(e)); process.exit(1); });
} else {
  console.error("usage: node .io/tests/io-suite.ts <nim|meta|read> [rounds]");
  process.exit(2);
}
