// .io/types.ts -- shared contracts for the model I/O layer. Erasable TS only (Node 24 runs .ts directly).

export type EngineId = "nimApi" | "metaChatCdp" | "manual";
export type Site = "metaAi" | "chatgpt" | "claude";

export interface AskOptions {
  // metaChatCdp only: explicit tab id. Required on purpose -- a tab is never
  // auto-picked, so Sam's Hindsight chat can never receive a scripted send.
  tabId?: string;
  system?: string;
  timeoutMs?: number;
  maxTokens?: number;
}

export interface AskResult {
  engine: EngineId;
  reply: string;
  ms: number;
  meta: Record<string, string | number>;
}

export type Parsed<T> =
  | { ok: true; value: T; ms: number; engine: EngineId }
  | { ok: false; error: string; ms: number };

export interface ChatRead {
  site: Site;
  tabId: string;
  url: string;
  text: string;
  ms: number;
}
