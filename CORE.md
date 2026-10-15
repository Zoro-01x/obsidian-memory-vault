---
aliases: ['core', 'memory index']
basis: observed
description: Always-loaded memory index for every session; seven vault tools. Hard budget ~1500 tokens.
name: CORE
scope: vault
status: active
updated: '2026-10-15'
verified: '2026-10-14'
---

# Memory ? core

This vault is **my** long-term memory. I am an AI coding agent with a session
boundary: each conversation starts fresh and context gets truncated. These
notes persist across my sessions. They are small, curated, and human-auditable.

Gemini and Claude are **sources I consult**, not members with their own memory
? the same role as a web search. I ask, they answer, and **I** judge what is
worth keeping and write it myself. There is one writer.

## Session protocol (do this, or the memory does not work)

Memory is exposed as seven tools: `core`, `recall`, `read`, `create`,
`append`, `propose`, `stale`.

**At start:**
1. Call `core` ? this file, budget-capped.
2. Call `recall` for anything relevant to the task *before* starting it, then
   `read` a hit before acting on it. Multiple keywords are ORed and ranked by
   how many match, so natural multi-word queries are fine.

**At end, if something durable happened:**
3. `create` it if I verified it myself ? `propose` if it came from an external
   model or was captured under context pressure and is still unverified ?
   `append` to update an existing note (its `set` argument edits frontmatter ?
   that is how a note gets retired).
4. Run `stale`: it lists `inbox/` items older than **7 days** (promote or
   delete ? an inbox nobody drains is a graveyard) plus code facts not
   rechecked lately.

## What this vault is for

Durable facts, decisions, lessons, and project state. Not transcripts.

**Write only if both are true:** this would change what a future agent does or
says, AND it will still be true in three months.

**Never write:** transcripts, generic knowledge, speculation, secrets, task
state, anything derivable from the repo itself.

## Where things go

| Folder | Contents |
|---|---|
| `inbox/` | Not-yet-trusted: external-model claims, statements captured under context pressure. |
| `entities/` | Projects, systems, people, tools. Continuously rewritten. |
| `decisions/` | What was decided, why, alternatives rejected. |
| `lessons/` | "Tried X, failed because Y". |

For anything I observed myself, **write directly** ? the inbox is only for
content I still need to judge.

## Frontmatter (all seven, always)

`name`, `description`, `aliases`, `status`, `updated`, `basis`, `scope`.

Optional: `superseded_by` (when status is superseded), `verified` (date).

**`basis`** is where a note came from: `user-stated` (you said it) ?
`observed` (I verified it) ? `external-model` (Gemini/Claude/web said it,
unverified) ? `inferred` (I concluded it). External-model claims are where
hallucination enters ? do not promote one to fact without checking.

**`scope`** is which project/repo this applies to. Without it, a convention
learned in one repo leaks into another.

**`verified`** is required for any note about code or environment state. A
confident memory about code that has since changed is the dominant failure
mode here ? recheck before relying on it.

Relationships are body `[[wikilinks]]`, never frontmatter.

Dropped: `type` (redundant with the folder), `created` (git has it),
`source`/`confidence` (both merged into `basis`).

## Current state

- **Memory substrate:** plain markdown + wikilinks + git. No vector DB, no
  hosted service. Rationale in [[Council memory substrate]].
- **Write path:** the seven tools above call the constrained verbs in
  `.system/vault-lib.ps1`; rules in [[Council write protocol]]. This is now a
  real boundary for the edit/write/patch tools ? content folders are denied in
  `opencode.jsonc`, so notes can only be written through the verbs, which
  validate the schema before writing. For **shell** it is only a *tripwire*:
  shell has full filesystem authority and matching is on command text, so a
  path built indirectly slips past. **git is still the actual safety net.**

- **Library size:** 19 functions, all reachable from the 7 verbs; the one
  orphan was removed rather than left to drift. Three checks:
  `.system/smoke-test.mjs` is read-only and safe any time (17/17);
  `.system/write-validation-test.ps1` proves schema + `-Set` rules and runs a
  commit-isolation test against a **throwaway repo in TEMP** (34/34);
  `.system/cold-start-test.mjs` re-spawns the wrapper as OpenCode would
  (command read from `opencode.jsonc`, foreign cwd) and asserts all 7 verbs
  come back plus `git`/`rg` resolve ? run it after any wrapper, config or
  Node change, because a wrapper can work in the session that built it and
  still fail cold.
- **If `vault` is absent on a fresh session, say so and treat memory as
  unavailable** for that session rather than continuing on the model's own
  recall ? a silent failure looks identical to an empty memory.
- **Obsidian:** a human viewer only. It is deliberately **not** on my critical
  path ? see [[Obsidian CDP access]] for why the CDP graph path was removed.
- **Backup:** none off-disk. Local git on the same drive is not a backup.
  Known gap.
