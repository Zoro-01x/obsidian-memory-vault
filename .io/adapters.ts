// .io/adapters.ts -- per-site composer send + conversation extraction.
// Design rules (Phase 0 receipts): DOM focus only, never screen coordinates;
// reply completion = stable extracted region (string equality), never a regex
// over page text (a regex matches words inside the model's own answer).

import type { Cdp } from "./util.ts";
import { sleep } from "./util.ts";
import type { Site } from "./types.ts";

const SELECTORS = [
  "#prompt-textarea",
  'div[contenteditable="true"]',
  'div[role="textbox"]',
  "textarea",
];
const SEL = JSON.stringify(SELECTORS);

const LEN_EXPR = `(()=>{let best=0;for(const s of ${SEL}){for(const el of document.querySelectorAll(s)){const r=el.getBoundingClientRect();if(r.width>150&&r.height>20){const t=el.innerText||el.value||'';if(t.length>best)best=t.length}}}return best})()`;

const FOCUS_EXPR = `(()=>{const sel=${SEL};let best=null,bs=0;for(const s of sel){for(const el of document.querySelectorAll(s)){const r=el.getBoundingClientRect();if(r.width>150&&r.height>20){const sz=r.width*r.height;if(sz>bs){bs=sz;best=el}}}}if(!best)return false;best.scrollIntoView({block:'center'});best.focus();try{best.click()}catch(e){}return true})()`;

// Sam's Hindsight chat. Scripts must never send here and never auto-pick it.
export const FORBIDDEN_PROMPT_IDS = ["AA439E61-09F9-4A15-9653-8E1A95BA8944"];

// UI chrome lines that may sit between prompt echo and the actual answer.
const NOISE_LINES = new Set([
  "Today",
  "Show thinking",
  "Show more",
  "Edit",
  "Message collapsed",
  "Latest response",
  "Think",
  "Response complete",
  "\u2026",
]);

export function stripNoise(text: string): string {
  return text
    .split("\n")
    .filter((l) => !NOISE_LINES.has(l.trim()))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// Cut the conversation region out of a page's full body text.
export function extractConversation(body: string, site: Site): string {
  if (site === "metaAi") {
    let t = body;
    const profile = body.lastIndexOf("x0_sam_0x");
    if (profile >= 0) t = body.slice(profile + "x0_sam_0x".length);
    const end = t.lastIndexOf("Ask Meta AI...");
    if (end >= 0) t = t.slice(0, end);
    return t.trim();
  }
  let t = body;
  const start = body.indexOf("You said:");
  if (start >= 0) t = body.slice(start);
  const sentinels =
    site === "chatgpt"
      ? ["ChatGPT can make mistakes.", "Ask ChatGPT"]
      : ["Write a message\u2026", "Claude is AI and can make mistakes."];
  let cut = -1;
  for (const s of sentinels) {
    const i = t.indexOf(s);
    if (i >= 0 && (cut < 0 || i < cut)) cut = i;
  }
  if (cut >= 0) t = t.slice(0, cut);
  return t.trim();
}

// Focus the composer through the DOM. Throws on failure -- by design there is
// no coordinate fallback; a broken focus means the UI changed and the adapter
// needs re-mapping, not guessing.
async function focusComposer(cdp: Cdp): Promise<void> {
  const ok = await cdp.evalJs(FOCUS_EXPR);
  if (ok !== "true") {
    throw new Error("composer focus failed -- UI selectors changed (re-map adapters.ts; no coordinate fallback by design)");
  }
  await sleep(400);
}

// A stale draft (left by an earlier failed send or a nav) would append to the
// next prompt and corrupt it -- select-all and delete before every insert.
// After clearing, VERIFY: a non-empty leftover must fail LOUD (a prompt glued
// onto a stale draft would sail through the landing check and corrupt both).
// len<=1 counts as empty -- this variant keeps a single stray paragraph char.
async function clearComposer(cdp: Cdp): Promise<void> {
  const len = await composerLen(cdp);
  if (len <= 1) return;
  await cdp.evalJs(
    "(()=>{try{document.execCommand('selectAll');return 'sel'}catch(e){return 'no'}})()",
  );
  await cdp.send("Input.dispatchKeyEvent", {
    type: "rawKeyDown", key: "Backspace", code: "Backspace",
    windowsVirtualKeyCode: 8, nativeVirtualKeyCode: 8,
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp", key: "Backspace", code: "Backspace",
    windowsVirtualKeyCode: 8, nativeVirtualKeyCode: 8,
  });
  await sleep(300);
  const after = await composerLen(cdp);
  if (after > 3) {
    throw new Error("composer draft not clearable (len=" + after + " after select-all+delete) -- refusing to append onto a stale draft");
  }
}

// New UI (observed 2026-10-21 17:xx): the composer has an explicit send
// button and Enter NO LONGER SENDS (the 20 failed acceptance rounds). Click
// the button by testid; fall back to Enter only when the button is absent
// (older variant), so both UIs work and both fail loud when neither does.
async function pressSend(cdp: Cdp): Promise<"button" | "enter"> {
  const res = await cdp.evalJs(
    "(()=>{const b=document.querySelector('[data-testid=\"composer-send-button\"]');" +
      "if(!b)return 'absent';const r=b.getBoundingClientRect();" +
      "if(r.width<4||r.height<4)return 'absent';" +
      "if(b.disabled||b.getAttribute('aria-disabled')==='true')return 'disabled';" +
      "b.click();return 'clicked';})()",
  );
  if (res === "clicked") return "button";
  if (res === "disabled") throw new Error("send button present but disabled -- composer content not accepted");
  await cdp.send("Input.dispatchKeyEvent", {
    type: "rawKeyDown", key: "Enter", code: "Enter",
    windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13,
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp", key: "Enter", code: "Enter",
    windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13,
  });
  return "enter";
}

async function composerLen(cdp: Cdp): Promise<number> {
  return +(await cdp.evalJs(LEN_EXPR)) || 0;
}

// Reload and scroll to the bottom: this variant's remount leaves lazily
// rendered content (new echo / reply) out of innerText until kicked.
async function reloadMaterialize(cdp: Cdp): Promise<void> {
  try {
    await cdp.send("Page.reload", { ignoreCache: false });
  } catch {
    /* next poll still reads whatever rendered */
  }
  await sleep(2500);
  try {
    await cdp.evalJs("window.scrollTo(0, document.body.scrollHeight); 'ok'");
  } catch {
    /* scroll kick is best-effort */
  }
  await sleep(1200);
}

// Occurrences of a needle in a haystack (snippet = 60 chars, no overlaps).
function countOccurrences(hay: string, needle: string): number {
  let n = 0, at = hay.indexOf(needle);
  while (at >= 0) { n++; at = hay.indexOf(needle, at + needle.length); }
  return n;
}

// Focus, clear stale draft, insert, verify NEAR-FULL landing, send, verify the
// NEW message reached the transcript. Delta check: the snippet may already
// exist in older messages (identical suite prompts in the same conversation),
// so presence alone is a false positive -- require the occurrence COUNT to
// grow, or the URL to change (new chat created).
export async function sendPrompt(cdp: Cdp, prompt: string, snippet: string, opts: { reload?: boolean } = {}): Promise<void> {
  await focusComposer(cdp);
  await clearComposer(cdp);
  await cdp.send("Input.insertText", { text: prompt });
  // 0.9 floor: a truncated draft (first-line-only, observed on the welcome
  // screen) must fail LOUD here instead of sending a sliced prompt.
  const needed = Math.max(20, Math.floor(prompt.length * 0.9));
  let len = 0;
  for (let i = 0; i < 12; i++) {
    len = await composerLen(cdp);
    if (len >= needed) break;
    await sleep(500);
  }
  if (len < needed) {
    throw new Error("prompt did not land whole in composer (len=" + len + ", needed=" + needed + " of " + prompt.length + ")");
  }
  const pre = (await cdp.evalJs("document.body.innerText")) || "";
  const preCount = countOccurrences(pre, snippet);
  const preUrl = await cdp.evalJs("location.href");
  const via = await pressSend(cdp);
  // Fast accept: the message leaving the composer (comp<30) means Meta's
  // client took it. Echo RENDERING is racy under rate limiting (message can
  // land seconds later) -- the waiter's bounded anchor window owns that
  // instead of burning 30s here per round.
  let confirmed = false;
  let comp = -1;
  const tSend = Date.now();
  for (let i = 0; i < 10; i++) {
    await sleep(700);
    comp = await composerLen(cdp);
    if (comp < 30) {
      confirmed = true;
      break;
    }
  }
  const seen = countOccurrences((await cdp.evalJs("document.body.innerText")) || "", snippet);
  const url = await cdp.evalJs("location.href");
  if (!confirmed) {
    throw new Error(
      "send not accepted (via=" + via + ", composerLen=" + comp + " after " + (Date.now() - tSend) + "ms, snippetCount=" + seen + " of pre " + preCount + ", urlChanged=" + (url !== preUrl) + ")",
    );
  }
}

// Locate the prompt echo inside the region and return everything after it.
// Full-prompt anchor: Meta renders user bubbles contiguously, so an exact
// lastIndexOf works; if a UI change ever soft-wraps the bubble, a
// whitespace-tolerant retry catches it. Returns null when neither matches --
// the caller fails LOUD rather than feeding prompt remainders to a reviewer.
function sliceAfterPrompt(region: string, prompt: string): string | null {
  const at = region.lastIndexOf(prompt);
  if (at >= 0) return region.slice(at + prompt.length);
  const esc = prompt.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/ /g, "\\s+");
  try {
    const m = region.match(new RegExp(esc));
    if (m && typeof m.index === "number") return region.slice(m.index + m[0].length);
  } catch {
    /* fall through to null */
  }
  return null;
}

// Wait until the reply REGION (extracted conversation after the FULL prompt
// echo) exists and stops changing. Completion is string equality across
// polls -- immune to words inside the answer itself.
//
// metaAi variant (observed 2026-10-21 evening): the live view renders USER
// messages but stops appending ASSISTANT responses until a re-render --
// answers exist server-side and appear on reload (PONG7/round1/round2/PONG8
// all confirmed post-reload while the live view stayed empty past 180s).
// So after a grace period, each poll = Page.reload + re-extract. chatgpt and
// claude keep plain polling (their live render has always worked).
export async function waitForStableReply(
  cdp: Cdp,
  site: Site,
  promptEcho: string,
  opts: { pollMs?: number; minStable?: number; timeoutMs?: number } = {},
): Promise<string> {
  const pollMs = opts.pollMs ?? 3000;
  const reloadMode = site === "metaAi";
  const minStable = opts.minStable ?? (reloadMode ? 3 : 4);
  const timeoutMs = opts.timeoutMs ?? 180000;
  const graceMs = 10000; // let the client FLUSH the send before reloading (reload pre-flush can drop it)
  const started = Date.now();
  let last = "";
  let stable = 0;
  let lastLen = -1;
  let anchorMisses = 0;
  while (Date.now() - started < timeoutMs) {
    const body = (await cdp.evalJs("document.body.innerText")) || "";
    const region = extractConversation(body, site);
    const sliced = sliceAfterPrompt(region, promptEcho);
    if (sliced === null) {
      // This variant remounts the conversation on send -- the echo can be
      // absent for a few seconds. Tolerate a bounded grace window (with
      // reloads to materialize), then fail LOUD rather than risk treating
      // prompt remainders as a reply.
      anchorMisses++;
      if (Date.now() - started > 45000) {
        throw new Error(
          "prompt echo never appeared in transcript region within 45s (" + anchorMisses + " polls, anchor lost) -- refusing to treat the echo as a reply",
        );
      }
      if (reloadMode && Date.now() - started >= graceMs) {
        await reloadMaterialize(cdp);
      } else {
        await sleep(pollMs);
      }
      continue;
    }
    const clean = stripNoise(sliced);
    lastLen = clean.length;
    // Any real content counts; stability (flat polls) is the signal.
    // minChars must stay tiny -- a correct short answer like {"round":1} is 12 chars.
    if (clean.length >= 2 && clean === last) {
      stable++;
      if (stable >= minStable) return clean;
    } else {
      stable = 0;
    }
    last = clean;
    if (reloadMode && Date.now() - started >= graceMs) {
      await reloadMaterialize(cdp);
    } else {
      await sleep(pollMs);
    }
  }
  throw new Error(
    "reply did not stabilize within " + timeoutMs + "ms (last reply-part length " + lastLen + ")",
  );
}
