// .io/util.ts -- CDP connection helpers. Read-only helpers for pages; sends go
// through adapters.sendPrompt only. No coordinate geometry anywhere by design.

export interface TabInfo {
  id: string;
  url: string;
  title: string;
  ws: string;
}

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export async function listTabs(): Promise<TabInfo[]> {
  const res = await fetch("http://127.0.0.1:9222/json/list");
  if (!res.ok) throw new Error("CDP list failed: HTTP " + res.status + " (is Brave running with --remote-debugging-port=9222?)");
  const arr = (await res.json()) as Array<Record<string, string>>;
  return arr
    .filter((t) => t.type === "page")
    .map((t) => ({ id: t.id, url: t.url || "", title: t.title || "", ws: t.webSocketDebuggerUrl || "" }));
}

export interface Cdp {
  send(method: string, params?: Record<string, unknown>): Promise<unknown>;
  evalJs(expr: string): Promise<string | null>;
  close(): void;
}

export async function connect(wsUrl: string): Promise<Cdp> {
  const ws = new WebSocket(wsUrl);
  await new Promise<void>((res, rej) => {
    ws.addEventListener("open", () => res(), { once: true });
    ws.addEventListener("error", () => rej(new Error("CDP websocket failed")), { once: true });
  });
  let nextId = 1;
  const send = (method: string, params?: Record<string, unknown>): Promise<unknown> =>
    new Promise((res, rej) => {
      const myId = nextId++;
      const on = (ev: MessageEvent) => {
        const m = JSON.parse(String(ev.data)) as { id?: number; result?: unknown; error?: unknown };
        if (m.id !== myId) return;
        ws.removeEventListener("message", on);
        if (m.error) rej(new Error(JSON.stringify(m.error)));
        else res(m.result);
      };
      ws.addEventListener("message", on);
      ws.send(JSON.stringify({ id: myId, method, params: params || {} }));
    });
  const evalJs = async (expr: string): Promise<string | null> => {
    try {
      const v = (await send("Runtime.evaluate", { expression: expr, returnByValue: true })) as {
        result?: { value?: unknown };
      };
      const val = v?.result?.value;
      return typeof val === "string" ? val : val == null ? null : String(val);
    } catch {
      return null;
    }
  };
  return { send, evalJs, close: () => ws.close() };
}
