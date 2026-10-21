# Obsidian Memory Vault

A personal long-term memory layer for an AI coding agent.

Plain markdown notes, versioned in git, exposed to the agent over MCP as eight
constrained verbs. No database, no embeddings, no server process.

## The one-sentence version

**It is a memory layer where every claim must declare how it is known** — each
note carries its provenance (`basis`) and, for code/environment claims, when it
was last checked (`verified`); writes are refused at the door if that
provenance is missing or malformed. What this does *not* do: verify that the
writer is being honest. A model can still declare `basis: observed` for
something it never observed — the schema makes that declaration explicit and
reviewable, not impossible.

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

## The eight verbs

| Verb | What it does |
|------|--------------|
| `core` | The always-loaded index, hard-capped to a token budget so it cannot eat the session |
| `recall` | Retrieval — ranked search across notes, returns vault-relative paths |
| `read` | Read one note: frontmatter, body, backlinks, plus a live schema check |
| `create` | Write a permanent note. Validates **before** writing. Refuses on name/alias collision |
| `append` | Append to a note, or replace a body explicitly. `set` edits frontmatter through a whitelist |
| `propose` | Stage an **unverified** claim into `inbox/` — for things you did not observe yourself |
| `stale` | Read-only prune pass: old inbox items and unverified code facts |
| `verify` | The witness: executes the probe frozen in the note's frontmatter against the world, appends to an evidence log the write verbs cannot reach. Never edits the note |

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

Vocabulary guards are **closed and case-sensitive**, verified per entry point:

| Input | Result | Why |
|-------|--------|-----|
| `status: Active` (wrong case) | refused | `-notin` is case-insensitive in PowerShell; the guards use `-cnotin` so `Active` cannot enter the vocabulary alongside `active` |
| `status: ''` (empty) | refused | An empty string is falsy, so a truthiness guard skips it; presence is checked with `ContainsKey` instead |
| `set @{ STATUS = ... }` (wrong-case key) | refused | Hashtable key matching is case-insensitive; the whitelist uses `-cnotcontains` so a wrong-case key cannot create a new field with its own casing |
| code-shaped claim into `inbox/` | **accepted** | Staging is unverified by construction — `propose` cannot pass a `verified` date, so refusing code-shaped claims at the door made the most valuable claims unstaggable and pushed the agent toward laundering them as `observed`. The rule bites at *promotion*: the identical description is still refused in `entities/`, `decisions/`, `lessons/` (both directions pinned in `write-validation-test.ps1`) |

The `set` whitelist is what makes retiring a note possible at all — without it,
`status: superseded` would be unreachable and every note would live forever as
`active`. Immutable by the same whitelist: `name`, `updated`, `created`,
`type`, `author`, `verified`, and every `probe_*` field.

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
   same note. Recency adds a small boost; `stale` and `superseded` subtract;
   `external-model` subtracts a small amount so an unchecked rumour cannot tie
   an observed+verified note on equal relevance. And when a superseded note and
   its named successor are both in the result set, the successor is forced
   above — a flat penalty cannot guarantee that, because the retired note's
   *name* may match the query better. Found by `adversarial-demo-test.ps1`
   (2026-10-18): before these two rules, an unchecked contradiction tied the
   verified note at 31.5, and a superseded inbox item outranked its own
   successor 32.5 → 31.5. The demo caught two real ranking defects on its
   first run; the fixes are pinned by its assertions.

**No embeddings, no vector store.** For a few hundred notes, grep plus the
wikilink graph is enough, and frontmatter aliases cure most vocabulary-mismatch
misses. This is a deliberate trade, not an omission — if your queries are
paraphrases rather than shared vocabulary, this will under-perform and you
should know that before you try it.

## Running it

All suites are safe. None writes to the real vault.

```bash
# read-only end-to-end across all 8 verbs
node .system/smoke-test.mjs

# the wrapper, spawned cold from a foreign working directory
node .system/cold-start-test.mjs

# schema enforced before writes; -Set whitelist; a refusal stages nothing
powershell -NoProfile -ExecutionPolicy Bypass -File .system/write-validation-test.ps1

# git's LF->CRLF stderr warning must never turn a committed write into a REFUSED
powershell -NoProfile -ExecutionPolicy Bypass -File .system/native-stderr-test.ps1

# the verify verb: probes, canary controls, fail-closed, drift axes
powershell -NoProfile -ExecutionPolicy Bypass -File .system/verify-test.ps1

# registry.json: one source of truth, every entry point still refuses bad vocabularies
powershell -NoProfile -ExecutionPolicy Bypass -File .system/registry-test.ps1

# adversarial demo: seed -> retrieve -> refuse promotion -> promote -> contradict
powershell -NoProfile -ExecutionPolicy Bypass -File .system/adversarial-demo-test.ps1
```

Expected outcome for each: **all pass, zero fail.** Verified 2026-10-18.
Treat that as a record of that day, not a standing claim — run the commands
above.

### The live demo (one command)

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File demo.ps1
```

A transcript proves nothing — anyone can paste green output. This builds a
**fresh clone of the pushed commit from GitHub** into `%TEMP%` and runs
everything against that clone, live, printing as it goes:

1. clone from GitHub (falls back to the local repo only if GitHub is
   unreachable, and prints that substitution loudly — never silent);
2. all six suites against the clone, output streaming;
3. the adversarial demo (the story, 32 assertions);
4. the with/without claim demo (same task, memory present vs absent);
5. **sabotage**: flips both status guards back to case-insensitive — the real
   historical defect — shows `registry-test` red at **94/97** with the three
   wrong-case assertions named and the CONTROL rows still green, restores the
   file from git, shows **97/97** again;
6. verdict: clone HEAD never moved, real vault read-only throughout.

Expected outcome: `EVERY PHASE BEHAVED AS EXPECTED`, exit 0 — measured 179s
(2026-10-18). `-Quick` skips the five supporting suites; `-Keep` leaves the
clone behind for inspection. Nothing is pushed; the real vault is never a write
target. Exit 0 means every phase behaved *as expected*, including the sabotage
being caught — a suite that stayed green after the guard was broken would be
reported as a demo failure, loudly.

### Pre-commit hook

A `.githooks/pre-commit` hook (enabled via `git config core.hooksPath .githooks`)
runs `registry-test.ps1` automatically — but only when a vocabulary-bearing
file is staged (`.system/registry.json`, `vault-lib.ps1`, `vault-adapter.ps1`,
`registry-test.ps1`, `vault-mcp.mjs`). Note commits stay fast; the suite runs
exactly when a vocabulary or its guard changes, which is the only commit where
"forgot to run it" can smuggle a broken guard through. It fails closed: if the
suite cannot run, the commit is blocked.

The honest ceiling: this removes the forgotten-run failure. It is **not**
independent review — the human is still the attestor for vocabulary changes.
A fresh clone does not get the hook automatically (`.git/hooks` is not
tracked); re-enable it with the config line above.

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

### Pre-push guard

The scanner above was originally wired to nothing — a manual run found it red
on already-pushed history (2026-10-21), which is the failure mode it exists
to prevent. `.githooks/pre-push` (same `git config core.hooksPath .githooks`
enablement as the pre-commit hook) now runs `.githooks/pre-push-guard.ps1`,
which fails closed:

1. **scanner** — the whole-history scan above, verbatim, exit 0 required;
2. **baseline anchor** — if the *committed* baseline differs from the last
   anchor in the append-only `.system/push-audit.jsonl`, the push blocks
   until the owner runs `.\audit-baseline.ps1 -Reason '...'`. Accepting
   findings without a dated, written reason is the rubber stamp; this makes
   it leave a trail. (The agent-edit deny on the baseline file is the same
   principle: acceptance is an owner action, recorded, never silent);
3. **provenance** — any `basis:` value changed inside the pushed commits is
   printed `old -> new` and recorded (reported, not blocked — owner edits
   are ordinary work; they must be *visible*, not forbidden);
4. **shadow notes** — `.md` files inside the vault that git ignores are
   listed; they are invisible to `git status` and to every gate that reads
   tracked files;
5. **index drift** — `CORE.md` wikilinks that point at no note are named;
6. **gate digests** — SHA-256 of the gate scripts rides in each audit entry,
   so a later edit to the grader itself shows up as a diff in history.

Every push attempt appends one JSON line to `.system/push-audit.jsonl`,
pass or blocked. Honest ceiling: this makes silent skips *evident*, not
impossible — erasing an entry means rewriting pushed history, which the
whole-history scanner also sees. A fresh clone needs the `hooksPath` line
above, same as the pre-commit hook.

### Attack mode: you break it, the gates grade it

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File attack-mode.ps1
```

The scripted demo proves you catch the defect you already know about. That is
a floor, not a claim. Act two removes your hands from the wheel: **the
recipient's own agent picks the attack**, and the gates grade what it did. A
hole found live is the demo succeeding, not failing — it becomes a permanent
test. The only way to fail is to hide one.

`attack-mode.ps1` runs five phases:

1. **Build** — `.system/attack-pack.ps1` makes a scrubbed sandbox under
   `%TEMP%`: a clean-room `git init` with **one plumbing commit at a fixed
   date**, so for a given package every build produces the identical start
   hash (measured twice in a row on the shipped file set: `fa018876`). It is
   never a copy of this repo — a clone, even
   with the notes swapped out, still carries the real history inside its
   packfiles. The note set is **replaced, not redacted**: every name in
   `synthetic/` is invented; nothing derived from a real note travels, because
   a rewritten copy leaks what it rewrote. Before anything is built, the
   SHA-256 of the gate scripts is printed — publish those with the zip; they
   are the recipient's anchor outside the package. A leak scan then runs over
   every shipped file (including `.git`) and refuses to hand over a sandbox
   with a single user path, credential shape or home directory in it.
2. **Anchor** — the pre-attack state (HEAD, refs, working tree, ignored
   files) is written *outside* the sandbox tree, where the attack cannot
   reach it.
3. **Calibrate** — a known violation is planted on purpose (a future-dated
   `verified:` claim with no record behind it). The checker must go red. If
   it does not, every later green is meaningless and the run fails loudly.
   Then it is removed, the repo is collected, and the checker must return to
   green. Scored as `KNOWN`, never as a find.
4. **Attack** — the sandbox is handed over with one instruction: *break its
   guarantees. Change what it says, what it stores, its history — your call.*
5. **Grade** — `invariant-check.ps1` reports the diff, the guarantees held
   and broken, tamper attempts, its own coverage, and — stated, not silently
   skipped — what it did **not** examine.

What the checker actually catches (measured, six representative attacks run
against a sandbox: false provenance claim, remote added, history amended,
checker edited, executable-surface config planted, file hidden on an ignored
path): **all six**, each named — including the edited checker itself,
detected by re-hashing every gate file against the build receipt. Exit 1,
`VIOLATIONS FOUND`.

**The trust model, stated plainly.** This script lives inside the package it
grades, so it cannot be its own authority. What you get is *local evidence,
independently inspectable* — not tamper-proof attestation. The anchors that
make it checkable are outside it: the published pre-build digests (recompute
with `Get-FileHash invariant-check.ps1 -Algorithm SHA256` and compare), and
the build receipt, written before any attack could start. Any timeout, crash
or missing baseline yields `UNDETERMINED` — never green. "No diff" is not
success; it is `NO_VIOLATION_OBSERVED`, within the coverage the output just
listed.

Measured honest ceilings, from building it: the scanner alone would have
reported *clean* on all six attacks above — it guards the vocabulary, not git
state; the static half is what saw them, which is why both halves exist and
why the dynamic half wants a disposable VM when it is used as evidence. An
attack that only touches files outside the package (PATH shims, a PowerShell
profile) leaves no diff for any checker here to find. And a returned artifact
over any channel — as opposed to this local, self-serve flow — must pass
symlink, junction and path-traversal rejection before anything reads it;
that check is not implemented here because this flow never receives one.

Nothing here touches the real vault: the sandbox has no remotes, no shared
object store, and no path to your notes. It is disposable — every run
rebuilds it from scratch, so re-running the command above always starts from
the same clean, deterministic baseline.

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
2. **The LF→CRLF defect is fixed, and the fix changed the story.**
   `vault-adapter.ps1` used to set `$ErrorActionPreference = 'Stop'`, under
   which a native command's **stderr becomes a terminating error**. Git warns
   on stderr about LF→CRLF, so `create`/`append` could report
   `REFUSED: warning: ...` **after the note had already been written and
   staged**. Fixed 2026-10-17 at one shared boundary (`Invoke-VaultNative`):
   stderr is captured as data, success is decided by `$LASTEXITCODE` alone.
   `native-stderr-test.ps1` is the regression suite.
   Correction to an earlier claim in this README: this did **not** reproduce
   in a fresh clone — `.gitattributes` pins `*.md`/`*.ps1`/`*.mjs`/`*.json`
   to `eol=lf`, which suppresses the warning at checkout. The old text said
   "a fresh clone with defaults will hit it"; that was wrong, and the
   wrongness was found by attempting the clone rather than reasoning about
   it.
3. **Scale untested.** The vault holds a handful of notes. Recall ranking,
   dedupe and the staleness rule have never been exercised at a size where they
   could fail.
4. **Retrieval is not semantic** — see [Retrieval](#retrieval).
5. **Nothing drains automatically.** The inbox follows a 7-day rule surfaced by
   the `stale` verb; a human runs it. Not built, on purpose.
6. **External models are not wired in as sources.** Gemini/Claude are consulted
   manually and judged by the writer; nothing writes to memory on their behalf.
7. **The Obsidian viewer is not running.** It is an optional human-facing window
   over the same files. The eight verbs do not need it.
8. **Model dependence — write-side form is enforced; read-side honesty is not.**
   The adapter refuses malformed writes no matter which model calls it, and no
   suite gates on model behaviour. What *does* depend on the operating model is
   what the model chooses to call and what it claims afterwards: a weak model
   can still declare `basis: observed` for something it never observed, skip
   `verify`, or report success on a call that never executed (NVIDIA
   DeepSeek-V4.1 via the NIM endpoint has been observed emitting tool-call
   markup as plain text). Tested operators, 2026-10-18, all seven suites green:
   **OpenCode-hosted models — full write/verify loop. NVIDIA NIM / DeepSeek via
   NIM — read-only recommended, not attested for write/verify.** These are
   dated test records, not permanent support claims; re-run the suites against
   a model before moving its tier.
9. **Not yet shown to improve work.** The suites prove the plumbing; the demo
   proves information availability. What has *not* been measured is whether an
   agent with this memory produces better work than one without.
10. **Private repository.** No outsider has cloned and reproduced it yet.

## Non-goals

Consolidation/promotion passes, embeddings, and using Obsidian as anything other
than a human viewer are out of scope. If you want those, this is the wrong tool.

---

*Verified 2026-10-18. Commands and expected outcomes above are current as of
that date; dated counts are a record of that day, not a standing claim.*
