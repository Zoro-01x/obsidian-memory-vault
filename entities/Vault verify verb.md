---
aliases: ['verify verb', 'witness', 'verification witness', 'probe registry']
basis: observed
description: 'verify is the witness: it executes a note''s frozen probe and records evidence no write verb can reach'
name: Vault verify verb
scope: vault
status: active
updated: '2026-10-17'
verified: '2026-10-17'
---

## What it is

`verify` is the 8th vault tool. It answers one question: **does the world
still satisfy the predicate this note declared?** It does NOT answer "is this
claim true?" -- a probe witnesses a **predicate**, not a proposition. (That
line came from ChatGPT; both Claude and Meta initially overclaimed that a probe
could make a claim true.)

## Design (Claude + Meta, independently, 2026-10-17)

- **The caller names a note and nothing else.** No outcome, no expected string,
  no verdict. Claude's test: *"replace the caller with a rock"* -- if the
  result still holds, it is a witness; if caller text moves it, it is a second
  opinion in a lab coat.
- **The probe is frozen at create time** and is absent from `append`'s `set`
  whitelist, so a writer cannot tune the probe after seeing what it returns.
- **Closed registry, 4 kinds**: `path_exists`, `file_hash`,
  `symbol_present`, `suite`. `suite` names one of four allowlisted tests by
  ID and never carries a command string -- otherwise verify is an injection
  surface with agent authority behind it.
- **Canary controls.** A probe that cannot fail proves nothing. Each kind runs a
  control that MUST fail; if the control passes, the probe's answer is
  DISCARDED and the outcome downgrades to failed.
- **Fail closed.** Exception, timeout, missing file, empty capture -- all
  `failed`. Never a pass.
- **Evidence goes to `.system/verify-log.ndjson`**, append-only and unreachable
  by every write verb (`.system` is in BlockedFolders). verify never edits the
  note -- the checker must not change the object it attests to.

## `verified` left the `set` whitelist

Both consultations converged on it independently. A model that can re-stamp
`verified` on a note it already wrote is certifying its own homework, and git
history keeps the unverified original while the note still READS as verified.
A model may declare `verified` at create; it can never re-certify later.

## The three axes (added after both AIs answered the same question)

`outcome` is a pure **conjunction** -- drift can only LOWER the verdict, never
raise it. But the axes are reported separately so the caller learns *why*:

| axis | meaning |
|---|---|
| `probe_ok` | did the predicate hold? |
| `drift` | `unchanged` \| `changed` \| `unrecorded` \| `unknown` |
| `spec_drift` | did the PROBE SPEC move? integrity violation, not staleness |

`unrecorded` (first verify, nothing to compare) and `unknown` (history exists
but is unreadable) are **not** the same. Treating unrecorded as unknown fails
every first verify; treating unknown as unrecorded lets a corrupt log silently
clear an edited note. Only the split is honest.

Spec drift is separate from body drift because the spec is not mutable through
the write path -- a differing spec means something bypassed it, which is louder
than staleness.

## What it does NOT catch

The note **body** is still largely unwitnessed. A probe can witness "this
symbol exists at line N of this file"; it cannot witness "this design is
correct". Claude named the residual honestly: *the claim-to-probe mapping is
where the model's judgment re-enters*. Ceiling: drift, deletion, schema rot.
Not correctness.

## Related

- [[Obsidian memory module]] -- the charter this serves.
- [[Council write protocol]] -- the single-writer rule that makes
  `basis` provenance meaningful.
- [[Council memory substrate]] -- why plain markdown, no vector DB.
