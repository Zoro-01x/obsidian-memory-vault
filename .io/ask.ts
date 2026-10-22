// .io/ask.ts -- give input, get results. Three engine slots behind one call:
//   nimApi      -- NVIDIA NIM (OpenAI-compatible), key from env or OpenCode store
//   metaChatCdp -- the meta.ai chat via CDP; tab must be named explicitly
//   manual      -- file exchange: you paste, the loop waits for your reply file
// askJson() parses-or-loudly-rejects: one parse retry, never a silent swallow.

import { writeFileSync, readFileSync, existsSync, unlinkSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { listTabs, connect, sleep } from "./util.ts";
import { sendPrompt, waitForStableReply, FORBIDDEN_PROMPT_IDS } from "./adapters.ts";
import { nvidiaKey } from "./secret.ts";
import type { AskOptions, AskResult, EngineId, Parsed, Site } from "./types.ts";

const NIM_URL = "https://integrate.api.nvidia.com/v1/chat/completions";
const NIM_MODEL = "deepseek-ai/deepseek-v4.1-flash";

// Parse a JSON object out of a reply. Strict first, then a salvage pass for
// invalid escapes (the judge quotes Windows paths like C:\Temp -- "\T" is an
// illegal JSON escape). Every candidate failure keeps its parse error so the
// caller can report WHY instead of a bare "no JSON".
function tryParseOne(s: string): { value?: unknown; err?: string } {
  try {
    return { value: JSON.parse(s) };
  } catch (e) {
    return { err: String((e as Error).message).slice(0, 160) };
  }
}

function salvageEscapes(s: string): string {
  // "\X" where X is not a legal JSON escape -> "\\X" (keeps the data exact).
  return s.replace(/\\([^"\\/bfnrtu])/g, "\\\\$1");
}

function extractJson(text: string): { value: unknown | null; error: string } {
  const candidates: string[] = [];
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) candidates.push(fenced[1].trim());
  const a = text.indexOf("{");
  const b = text.lastIndexOf("}");
  if (a >= 0 && b > a) candidates.push(text.slice(a, b + 1));
  candidates.push(text.trim());
  let lastErr = "no { } object found";
  for (const c of candidates) {
    if (!c) continue;
    for (const attempt of [c, salvageEscapes(c)]) {
      const r = tryParseOne(attempt);
      if (r.err === undefined) return { value: r.value, error: "" };
      lastErr = r.err;
    }
  }
  return { value: null, error: lastErr };
}

async function askNim(prompt: string, opts: AskOptions): Promise<AskResult> {
  const { source, key } = await nvidiaKey();
  if (!key) {
    throw new Error(
      "nimApi: no key. Checked env [" + ["NVIDIA_API_KEY", "NIM_API_KEY", "NGC_API_KEY"].join(", ") +
        "] and opencode store (source=" + source + ")",
    );
  }
  const started = Date.now();
  const ctrl = new AbortController();
  const to = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 60000);
  try {
    const messages: Array<{ role: string; content: string }> = [];
    if (opts.system) messages.push({ role: "system", content: opts.system });
    messages.push({ role: "user", content: prompt });
    const res = await fetch(NIM_URL, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + key },
      body: JSON.stringify({
        model: NIM_MODEL,
        messages,
        temperature: 1.0, // model card recommendation; do not lower
        max_tokens: opts.maxTokens ?? 1024,
        stream: false,
      }),
      signal: ctrl.signal,
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 240);
      throw new Error("nimApi HTTP " + res.status + ": " + body);
    }
    const j = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const reply = j.choices?.[0]?.message?.content ?? "";
    if (!reply) throw new Error("nimApi: empty reply (top-level keys: " + Object.keys(j).join(",") + ")");
    return { engine: "nimApi", reply, ms: Date.now() - started, meta: { source } };
  } finally {
    clearTimeout(to);
  }
}

async function askMetaChatCdp(prompt: string, opts: AskOptions): Promise<AskResult> {
  if (!opts.tabId) {
    throw new Error("metaChatCdp: opts.tabId is required -- tabs are never auto-picked (Hindsight chat must be unreachable by scripts)");
  }
  const tabs = await listTabs();
  const tab = tabs.find((t) => t.id === opts.tabId);
  if (!tab) throw new Error("metaChatCdp: tab not found: " + opts.tabId);
  if (!tab.url.includes("meta.ai")) throw new Error("metaChatCdp: tab is not meta.ai: " + tab.url);
  for (const id of FORBIDDEN_PROMPT_IDS) {
    if (tab.url.includes(id)) throw new Error("metaChatCdp: refusing -- that tab is the Hindsight chat");
  }
  const started = Date.now();
  const snippet = prompt.slice(0, 60); // presence check for sendPrompt only
  const cdp = await connect(tab.ws);
  try {
    await sendPrompt(cdp, prompt, snippet, { reload: true });
    // Reply anchoring uses the FULL prompt: slicing only the 60-char snippet
    // would leave the prompt's remainder in the reply (Phase 1 first run).
    const reply = await waitForStableReply(cdp, "metaAi", prompt, { timeoutMs: opts.timeoutMs ?? 180000 });
    return { engine: "metaChatCdp", reply, ms: Date.now() - started, meta: { tab: tab.id, url: tab.url } };
  } finally {
    cdp.close();
  }
}

const OUTBOX = fileURLToPath(new URL("./manual-outbox.txt", import.meta.url));
const INBOX = fileURLToPath(new URL("./manual-inbox.txt", import.meta.url));

async function askManual(prompt: string, opts: AskOptions): Promise<AskResult> {
  const started = Date.now();
  writeFileSync(OUTBOX, prompt, "utf8");
  console.log("[manual] paste " + OUTBOX + " into any chat, then save the reply as " + INBOX);
  const deadline = started + (opts.timeoutMs ?? 600000);
  while (Date.now() < deadline) {
    if (existsSync(INBOX)) {
      const st = statSync(INBOX);
      if (st.size > 0) {
        const reply = readFileSync(INBOX, "utf8").trim();
        unlinkSync(INBOX);
        if (reply) return { engine: "manual", reply, ms: Date.now() - started, meta: { source: "file" } };
      }
    }
    await sleep(2000);
  }
  throw new Error("manual: no reply file within timeout (" + Math.round((Date.now() - started) / 1000) + "s)");
}

export async function ask(engine: EngineId, prompt: string, opts: AskOptions = {}): Promise<AskResult> {
  if (engine === "nimApi") return askNim(prompt, opts);
  if (engine === "metaChatCdp") return askMetaChatCdp(prompt, opts);
  if (engine === "manual") return askManual(prompt, opts);
  throw new Error("unknown engine: " + String(engine));
}

// Structured ask: parse the reply as JSON, validate it, or fail loudly.
// Exactly one retry, and only for parse/validation failures.
export async function askJson<T>(
  engine: EngineId,
  prompt: string,
  validate: (v: unknown) => T | null,
  opts: AskOptions = {},
): Promise<Parsed<T>> {
  const started = Date.now();
  let lastError = "";
  for (let attempt = 1; attempt <= 2; attempt++) {
    const p =
      attempt === 1
        ? prompt
        : prompt + "\n\nOUTPUT RULE: reply with ONLY one valid JSON object. No prose, no code fences.";
    let reply: string;
    try {
      const r = await ask(engine, p, opts);
      reply = r.reply;
    } catch (e) {
      return { ok: false, error: String((e as Error).message), ms: Date.now() - started };
    }
    const parsed = extractJson(reply);
    if (parsed.value === null) {
      lastError =
        "no JSON object in reply (len=" + reply.length +
        ", parse: " + parsed.error +
        ", head=" + JSON.stringify(reply.slice(0, 80)) + ")";
      continue;
    }
    const v = validate(parsed.value);
    if (v === null) {
      lastError = "JSON failed validation: " + JSON.stringify(parsed.value).slice(0, 200);
      continue;
    }
    return { ok: true, value: v, ms: Date.now() - started, engine };
  }
  return { ok: false, error: lastError, ms: Date.now() - started };
}
