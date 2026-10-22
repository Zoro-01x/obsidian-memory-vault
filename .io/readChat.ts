// .io/readChat.ts -- pull a chat transcript off a live tab. READ ONLY: no
// clicks, no typing, no focus. This is the direction that has never failed.

import { listTabs, connect } from "./util.ts";
import { extractConversation, FORBIDDEN_PROMPT_IDS } from "./adapters.ts";
import type { ChatRead, Site } from "./types.ts";

const SITE_PATTERN: Record<Site, RegExp> = {
  metaAi: /meta\.ai\/prompt\//,
  chatgpt: /chatgpt\.com\/c\//,
  claude: /claude\.ai\/chat\//,
};

export async function readChat(site: Site, tabId?: string): Promise<ChatRead> {
  const started = Date.now();
  const tabs = await listTabs();
  let tab = tabId ? tabs.find((t) => t.id === tabId) : undefined;
  if (!tab && !tabId) {
    const forbidden = FORBIDDEN_PROMPT_IDS;
    tab = tabs.find(
      (t) => SITE_PATTERN[site].test(t.url) && !forbidden.some((f) => t.url.includes(f)),
    );
  }
  if (!tab) {
    throw new Error(
      "readChat: no " + site + " tab " + (tabId ? "(" + tabId + ")" : "(auto-pick, forbidden ids excluded)") + " found",
    );
  }
  const cdp = await connect(tab.ws);
  try {
    const body = (await cdp.evalJs("document.body.innerText")) || "";
    const text = extractConversation(body, site);
    if (text.length < 50) {
      throw new Error("readChat: extracted region too small (" + text.length + " chars) -- selectors likely stale");
    }
    return { site, tabId: tab.id, url: tab.url, text, ms: Date.now() - started };
  } finally {
    cdp.close();
  }
}
