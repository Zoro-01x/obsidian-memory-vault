// .council/maintain.ts -- the auto-maintenance lane (Sam-approved carve-out
// 2026-10-22: "without me independently... self learning and auto maintaining").
//
// Bounded by design:
//   - nothing is ever deleted; every write goes through vault-adapter.ps1
//     (path allowlist, closed vocabularies, schema check, atomic git commit),
//   - --dry-run previews the whole plan first,
//   - --limit caps how many actions one run may execute,
//   - every action gets a receipt in .council/maintain-log.jsonl.
// Push and consent rules are untouched: this lane never pushes, never contacts
// anyone, and never touches notes outside the four write folders.
//
// Actions (in order):
//   1. PROMOTE  council-green inbox claims: stamp `verdict=keep|modify` and
//      `confidence >= --min-conf` (default 0.75) -> create the permanent note
//      (lessons vs decisions by keyword), then mark the inbox item superseded
//      with a pointer to the new note. Claims that fail create (name collision,
//      code-shaped without a verified date) stay in the inbox and are reported.
//   2. FLIP     notes that carry superseded_by but status is still active ->
//      status=superseded. Detection exists (the pointer); this is the write side.
//   3. DEDUPE   active inbox items whose normalized title (timestamp stripped)
//      equals a permanent note name or alias -> superseded_by that note.
//      Receipts stay in git and in the run-logs; only the status moves.
//
// Usage: node .council/maintain.ts [--dry-run] [--min-conf 0.75] [--limit 20]

import { readFileSync, appendFileSync, existsSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { callAdapter, asciiFold } from "./file.ts";

const VAULT_ROOT = fileURLToPath(new URL("../", import.meta.url));
const LOG = fileURLToPath(new URL("./maintain-log.jsonl", import.meta.url));
const WRITE_FOLDERS = ["inbox", "entities", "decisions", "lessons"];
const PERMANENT = new Set(["entities", "decisions", "lessons"]);
const STAMP_RE = /\[council\s+\S+\s+chunk\s+\d+:\s*verdict=(keep|modify)\s+confidence=([0-9.]+)/;

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
function flag(name: string): boolean {
  return process.argv.includes("--" + name);
}

interface NoteFile {
  rel: string; // vault-relative, backslashes
  folder: string;
  name: string; // filename without extension
  fm: Record<string, string>;
  body: string;
}

function parseNote(abs: string, folder: string, rel: string): NoteFile {
  const text = readFileSync(abs, "utf8").replace(/^\uFEFF/, "");
  const fm: Record<string, string> = {};
  let body = text;
  if (text.startsWith("---")) {
    const end = text.indexOf("\n---", 3);
    if (end > 0) {
      const header = text.slice(3, end);
      body = text.slice(end + 4);
      for (const line of header.split("\n")) {
        const m = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
        if (m) fm[m[1].toLowerCase()] = m[2].trim();
      }
    }
  }
  const name = rel.replace(/\.md$/i, "").split("\\").pop() || rel;
  return { rel, folder, name, fm, body };
}

function loadFolder(folder: string): NoteFile[] {
  const dir = VAULT_ROOT + folder;
  if (!existsSync(dir)) return [];
  const out: NoteFile[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.toLowerCase().endsWith(".md")) continue;
    out.push(parseNote(dir + "\\" + f, folder, folder + "\\" + f));
  }
  return out;
}

function normalizeName(s: string): string {
  return s
    .replace(/\s*\(\d{4}-\d{2}-\d{2}-\d{6}\)\s*$/, "") // inbox timestamp suffix
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "")
    .trim();
}

function aliasesOf(n: NoteFile): string[] {
  const raw = n.fm.aliases || "";
  return raw.replace(/^\[|\]$/g, "").split(",").map((a) => a.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
}

function firstSentence(body: string, max = 160): string {
  const clean = body.split(/\n\n\[council/)[0].replace(/\s+/g, " ").trim();
  const cut = clean.match(/^[^.!?]*[.!?]/);
  const s = (cut ? cut[0] : clean).trim();
  return (s || clean).slice(0, max);
}

function pickFolder(title: string, body: string): "lessons" | "decisions" {
  const t = (title + " " + body.slice(0, 400)).toLowerCase();
  if (/\b(rule|lesson|never|always|must|pattern|style|standing|learned|habit)\b/.test(t)) return "lessons";
  return "decisions";
}

interface Planned {
  kind: "promote" | "flip" | "dedupe";
  path: string; // vault-relative source note
  detail: string;
  execute: () => Promise<{ ok: boolean; err?: string }>;
}

async function main(): Promise<void> {
  const dryRun = flag("dry-run");
  const minConf = parseFloat(arg("min-conf", "0.75") || "0.75");
  const limit = parseInt(arg("limit", "20") || "20", 10);

  const inbox = loadFolder("inbox");
  const permanent: NoteFile[] = [];
  for (const f of WRITE_FOLDERS) if (f !== "inbox") permanent.push(...loadFolder(f));

  const planned: Planned[] = [];
  const inboxHandled = new Set<string>();

  // --- 1. PROMOTE council-green -------------------------------------------
  for (const item of inbox) {
    const status = item.fm.status || "active";
    if (status !== "active") continue;
    const m = item.body.match(STAMP_RE);
    if (!m) continue;
    const conf = parseFloat(m[2]);
    if (!(conf >= minConf)) {
      console.log("skip (conf " + m[2] + " < " + minConf + "): " + item.rel);
      continue;
    }
    const title = item.name.replace(/\s*\(\d{4}-\d{2}-\d{2}-\d{6}\)\s*$/, "").trim().slice(0, 100);
    const folder = pickFolder(title, item.body);
    const body = asciiFold(item.body).slice(0, 3800);
    const description = asciiFold(firstSentence(item.body)) || asciiFold(title).slice(0, 160);
    const basis = ["observed", "user-stated", "inferred", "external-model"].includes(item.fm.basis)
      ? item.fm.basis
      : "inferred";
    const scope = item.fm.scope || "ObsidianVault";

    planned.push({
      kind: "promote",
      path: item.rel,
      detail: "council " + m[1] + " conf=" + m[2] + " -> " + folder + "\\" + title,
      execute: async () => {
        const created = await callAdapter("create", {
          folder,
          name: title,
          description,
          body,
          aliases: [],
          status: "active",
          basis,
          scope,
          author: "maintain",
        });
        if (!created.ok) return { ok: false, err: "create: " + String(created.error).slice(0, 180) };
        const createdPath = String((created.result as { created?: string } | undefined)?.created || "");
        const newName = createdPath.replace(/\.md$/i, "").split("\\").pop() || title;
        inboxHandled.add(item.rel);
        const ap = await callAdapter("append", {
          path: item.rel,
          set: { status: "superseded", supersededBy: newName },
          author: "maintain",
        });
        if (!ap.ok) return { ok: false, err: "created " + createdPath + " but supersede failed: " + String(ap.error).slice(0, 140) };
        return { ok: true };
      },
    });
  }

  // --- 2. FLIP pointer-without-status -------------------------------------
  for (const n of [...permanent, ...inbox]) {
    const pointer = n.fm.superseded_by || n.fm.supersededBy || "";
    const status = n.fm.status || "active";
    if (!pointer || status === "superseded") continue;
    planned.push({
      kind: "flip",
      path: n.rel,
      detail: "status " + status + " -> superseded (pointer: " + pointer + ")",
      execute: async () => {
        const r = await callAdapter("append", {
          path: n.rel,
          set: { status: "superseded", supersededBy: pointer },
          author: "maintain",
        });
        return r.ok ? { ok: true } : { ok: false, err: String(r.error).slice(0, 180) };
      },
    });
  }

  // --- 3. DEDUPE exact-normalized title against permanent names+aliases ----
  const permanentKeys = new Map<string, string>(); // normalized -> real note name
  for (const n of permanent) {
    permanentKeys.set(normalizeName(n.name), n.name);
    for (const a of aliasesOf(n)) permanentKeys.set(normalizeName(a), n.name);
  }
  for (const item of inbox) {
    if (item.fm.status !== undefined && item.fm.status !== "active") continue;
    if (inboxHandled.has(item.rel)) continue;
    const key = normalizeName(item.name);
    if (!key) continue;
    const hit = permanentKeys.get(key);
    if (!hit || hit === item.name) continue;
    planned.push({
      kind: "dedupe",
      path: item.rel,
      detail: "duplicate of " + hit + " -> superseded_by " + hit,
      execute: async () => {
        const r = await callAdapter("append", {
          path: item.rel,
          set: { status: "superseded", supersededBy: hit },
          author: "maintain",
        });
        return r.ok ? { ok: true } : { ok: false, err: String(r.error).slice(0, 180) };
      },
    });
  }

  // --- report / execute ----------------------------------------------------
  const todo = planned.slice(0, limit);
  console.log(
    "maintain: promote=" + planned.filter((p) => p.kind === "promote").length +
      " flip=" + planned.filter((p) => p.kind === "flip").length +
      " dedupe=" + planned.filter((p) => p.kind === "dedupe").length +
      (planned.length > todo.length ? " (capped at " + limit + ")" : "") +
      (dryRun ? " DRY-RUN" : ""),
  );

  if (planned.length > limit) {
    for (const p of planned.slice(limit)) console.log("  beyond limit: [" + p.kind + "] " + p.path + " -- " + p.detail);
  }

  let okCount = 0;
  let failCount = 0;
  for (const p of todo) {
    if (dryRun) {
      console.log("  DRY [" + p.kind + "] " + p.path + " -- " + p.detail);
      continue;
    }
    let res: { ok: boolean; err?: string };
    try {
      res = await p.execute();
    } catch (e) {
      res = { ok: false, err: String((e as Error).message).slice(0, 180) };
    }
    const entry = { ts: new Date().toISOString(), kind: p.kind, path: p.path, detail: p.detail, ok: res.ok, err: res.err || null };
    appendFileSync(LOG, JSON.stringify(entry) + "\n", "utf8");
    if (res.ok) {
      okCount++;
      console.log("  OK  [" + p.kind + "] " + p.path + " -- " + p.detail);
    } else {
      failCount++;
      console.log("  FAIL[" + p.kind + "] " + p.path + " -- " + res.err);
    }
  }

  const summary = {
    ts: new Date().toISOString(),
    dryRun,
    planned: planned.length,
    executed: dryRun ? 0 : okCount + failCount,
    ok: okCount,
    failed: failCount,
  };
  console.log("summary: " + JSON.stringify(summary));
  if (!dryRun && planned.length === 0) console.log("nothing to do -- vault is already tidy");
  process.exit(failCount > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error("FATAL " + String((e as Error).message));
  process.exit(1);
});
