# Obsidian Memory Vault

A personal long-term memory layer for an AI coding agent.

Plain markdown notes, versioned in git, exposed to the agent over MCP as seven
constrained verbs. No database, no embeddings, no server process.

## The one-sentence version

**It is a memory layer where a claim cannot silently become truth** — every note
carries how it is known (`basis`) and when it was last checked (`verified`), and
writes are refused at the door if that provenance is missing or malformed.

Obsidian stores notes. Git versions files. MCP exposes tools. Schema validation
checks structure. This project exists to enforce one behaviour those tools do not
enforce individually: **an inference stays visibly an inference until something
actually verifies it.**

## What it is not

- Not semantic search. Retrieval is keyword-based (see [Retrieval](#retrieval)).
- Not multi-user, not a service, not self-hosting anything.
- Not portable. Windows + PowerShell + a machine-specific ripgrep path.
- Not scaled. It runs against a handful of notes, not thousands — see
  [Limitations](#limitations).
- Not autonomous. Nothing drains, promotes or prunes without a person asking.

## The seven verbs

| Verb | What it does |
|------|--------------|
| `core` | The always-loaded index, hard-capped to a token budget so it cannot eat the session |
| `recall` | Retrieval — ranked search across notes, returns vault-relative paths |
| `read` | Read one note: frontmatter, body, backlinks, plus a live schema check |
| `create` | Write a permanent note. Validates **before** writing. Refuses on name/alias collision |
| `append` | Append to a note, or replace a body explicitly. `set` edits frontmatter through a whitelist |
| `propose` | Stage an **unverified** claim into `inbox/` — for things you did not observe yourself |
| `stale` | Read-only prune pass: old inbox items and unverified code facts |

Every verb runs as one fresh PowerShell process reading one JSON object from
stdin and writing one JSON object to stdout. Deliberately not a long-lived
process: a crashed daemon needs crash recovery, and a spawn per call needs none.

## Provenance is the schema

Seven required frontmatter fields: `name`, `description`, `aliases`, `status`,
`updated`, `basis`, `scope`. Plus `verified`, which is **required** for
code/environment claims.

`basis` is the interesting one:

| Value | Meaning |
|-------|---------|
| `user-stated` | The user said it |
| `observed` | Verified first-hand |
| `external-model` | Another model said it — **unverified by definition** |
| `inferred` | Reasoned, not confirmed |

This is what replaces the older `source` + `confidence` pair. The single-writer
setup does not remove the need for provenance — external-model claims are still
where hallucination enters, and a note sourced from another model must not read
like one you watched happen.

### Enforcement, not convention

Validation happens **before** the file is written, against in-memory data:

- a code-shaped note with no `verified` date → refused
- `verified: recently` → refused (must be `YYYY-MM-DD`)
- `status: banana` → refused (only `active` / `superseded` / `stale`)
- `name`, `updated`, `created`, `type`, `author` → not mutable via `set`

The `set` whitelist is what makes retiring a note possible at all — without it,
`status: superseded` would be unreachable and every note would live forever as
`active`.

Writes are also path-guarded: `..`, absolute paths, `.obsidian`, `.git`,
`.system` and unknown folders are rejected. A verb stages **only** the path it
wrote, never `git add -A`.

## Retrieval

Keyword search, honestly described:

1. Split the query into terms, match **any** of them using ripgrep (`-F`,
   case-insensitive, capped per file so one big note cannot dominate).
2. If ripgrep is unavailable or returns nothing, fall back to a literal
   `IndexOf` scan over every note.
3. Score, in order of weight: `name` +6, `aliases` +4, `description` +3,
   `scope` +2 per matched term, plus a bonus when several query terms match the
   same note. Recency adds a small boost; `stale` and `superseded` subtract.

**No embeddings, no vector store.** For a few hundred notes, grep plus the
wikilink graph is enough, and frontmatter aliases cure most vocabulary-mismatch
misses. This is a deliberate trade, not an omission — if your queries are
paraphrases rather than shared vocabulary, this will under-perform and you
should know that before you try it.

## Running it

All three suites are safe. None writes to the real vault.

```bash
# read-only end-to-end across all 7 verbs
node .system/smoke-test.mjs

# the wrapper, spawned cold from a foreign working directory
node .system/cold-start-test.mjs

# schema enforced before writes; -Set whitelist; a refusal stages nothing
powershell -NoProfile -ExecutionPolicy Bypass -File .system/write-validation-test.ps1
```

Expected outcome for each: **all pass, zero fail.**

Dated evidence (run 2026-10-16): `17/17`, `8/8`, `33/33`. Treat those numbers as
a record of that day, not a standing claim — run the commands above.

The write-validation suite builds a scratch repo under `%TEMP%` with a
`.vault-test-root` sentinel and refuses to run a single assertion unless the
resolved vault root is that scratch repo. That precondition exists because an
earlier version hard-coded the live vault path and committed straight into live
history during a restore proof.

### The scanner

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .system/pre-push-scan.ps1 -SelfTest  # must exit 0
powershell -NoProfile -ExecutionPolicy Bypass -File .system/pre-push-scan.ps1            # must exit 0 before any push
```

Pushing publishes **entire history**, not the current tree — a secret committed
and later scrubbed still ships in every old commit. So the scanner walks every
commit, and it guards against its own detectors silently matching nothing: the
self-test plants a secret, scrubs it in a *later* commit, and requires the scan
to still find it while the current tree is clean. If the self-test fails, the
verdict is void (exit 2), never clean.

Exit codes: `0` clean · `1` findings · `2` scanner or self-test failure.

## The demo: does memory change the answer?

```bash
node .system/demo-with-without.mjs
```

This is the claim, tested. It builds a throwaway vault under `%TEMP%` with
fabricated notes, runs one identical task twice, and changes exactly one
variable:

- **With memory** — a session cold-starts, `recall`s, reads the decision note,
  and the answer (with its provenance: `basis`, `verified`, `status`) is
  available.
- **Without memory** — same task, same code path, same cold spawn, no such note:
  the answer does not exist in the session, and the conventional default is what
  a developer would assume.

Same task, same code path, same cold spawn — the only variable is the note.

**What it does not show:** there is no model in that loop. It demonstrates
information *availability* to a cold session, not an agent reasoning. Sessions A
and B are two fresh spawns run back to back, not two days apart.

The demo never touches the real vault: `vault-lib.ps1` only honours
`OBSIDIAN_VAULT_ROOT` when the target is inside `%TEMP%` **and** carries the
`.vault-test-root` sentinel.

## Design decisions

| Decision | Why | Rejected |
|---|---|---|
| Plain markdown + git | Human-readable, diffable, greppable, survives the tooling | Vector DB / embeddings — premature at this scale |
| MCP spawn per call | No crash recovery to get right | Long-lived daemon |
| JSON on stdin | Note bodies are full of quotes and newlines; argv mangles them | `-File -Expression` arguments |
| Single writer | Two writers means a merge/policy layer nobody needs | Dual-member dispatcher, PROPOSE fence contract — built, then abandoned |
| Warn-only injection guard | A hard refuse blocked ordinary coding memory ("always use `pnputil`") | Blocking all `external-model` prose — patterns and tests had been written together, so the old "8/8 refused" proved little |
| No Obsidian CDP graph path | Port 9223 is arbitrary code execution inside Obsidian; grep was fast enough | Graph traversal over CDP |

**Authorship:** built by Zoro with an OpenCode agent. Commits are authored by
synthetic local identities (`harness@vault.local`, `migrate@vault.local`), which
is why they link to no GitHub account. That is deliberate for a private repo —
the scanner confirms identities are local-only and leak nothing real.

## Limitations

Stated plainly, because hiding them would be the disqualifying part:

1. **Windows-only.** PowerShell adapter, hard-coded ripgrep path,
   `%TEMP%`/sentinel isolation, and the baseline accepts known Windows-path
   findings. Someone on macOS or Linux cannot run this as-is.
2. **A real defect, found by the demo.** `vault-adapter.ps1` sets
   `$ErrorActionPreference = 'Stop'`, and under that setting a native command's
   **stderr becomes a terminating error**. Git warns on stderr about LF→CRLF when
   `core.autocrlf` is at its Windows default. So on a default-configured clone,
   `create`/`append` can report `REFUSED: warning: ...` **after the note has
   already been written and staged** — the write happened, the caller is told it
   was refused, and no commit exists.
   This repo sets `core.autocrlf = false`, so it does not trigger here; a fresh
   clone with defaults will hit it. It also means the suite's guarantee
   *"a refusal stages and commits nothing"* holds for validation refusals
   (thrown before the write) but **not** for failures after it.
3. **Scale untested.** The vault holds a handful of notes. Recall ranking,
   dedupe and the staleness rule have never been exercised at a size where they
   could fail.
4. **Retrieval is not semantic** — see [Retrieval](#retrieval).
5. **Nothing drains automatically.** The inbox follows a 7-day rule surfaced by
   the `stale` verb; a human runs it. Not built, on purpose.
6. **External models are not wired in as sources.** Gemini/Claude are consulted
   manually and judged by the writer; nothing writes to memory on their behalf.
7. **The Obsidian viewer is not running.** It is an optional human-facing window
   over the same files. The seven verbs do not need it.
8. **Not yet shown to improve work.** The suites prove the plumbing; the demo
   proves information availability. What has *not* been measured is whether an
   agent with this memory produces better work than one without.
9. **Private repository.** No outsider has cloned and reproduced it yet.

## Non-goals

Consolidation/promotion passes, embeddings, and using Obsidian as anything other
than a human viewer are out of scope. If you want those, this is the wrong tool.

---

*Verified 2026-10-16. Commands and expected outcomes above are current as of
that date; numbers are a dated record, not a standing claim.*
