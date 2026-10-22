// .io/secret.ts -- loads the NVIDIA key for nimApi. Precedence: env var, then
// OpenCode's credential store (read-only). The key value is returned to the
// caller for use in memory only and is never logged, written, or committed.

const STORE_DB = "C:/Users/Home/.local/share/opencode/opencode.db";
const ENV_NAMES = ["NVIDIA_API_KEY", "NIM_API_KEY", "NGC_API_KEY"];

let cached: { source: string; key: string | null } | null = null;

export async function nvidiaKey(): Promise<{ source: string; key: string | null }> {
  if (cached) return cached;
  for (const name of ENV_NAMES) {
    const v = process.env[name];
    if (v && v.length > 8) {
      cached = { source: "env:" + name, key: v };
      return cached;
    }
  }
  try {
    const { DatabaseSync } = await import("node:sqlite");
    const db = new DatabaseSync(STORE_DB, { readOnly: true });
    const row = db
      .prepare("SELECT value FROM credential WHERE integration_id = 'nvidia' AND active = 1 LIMIT 1")
      .get() as { value?: string } | undefined;
    db.close();
    if (row && row.value) {
      const parsed = JSON.parse(row.value) as { key?: string };
      if (parsed.key && parsed.key.length > 8) {
        cached = { source: "opencode-store", key: parsed.key };
        return cached;
      }
    }
    cached = { source: "store:present-but-empty", key: null };
  } catch (e) {
    cached = { source: "store:error:" + String((e as Error).message).slice(0, 80), key: null };
  }
  return cached;
}
