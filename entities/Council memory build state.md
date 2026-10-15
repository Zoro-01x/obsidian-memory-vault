---
aliases: ['handoff', 'build state', 'council progress', 'resume point', 'current state']
basis: observed
description: 'Handoff: single-writer memory vault built and tested (7 MCP verbs, 17/17 smoke tests). Read this to resume cold -- it also records what was abandoned and why.'
name: Council memory build state
scope: council
status: active
updated: '2026-10-15'
verified: '2026-10-15'
---

## What this vault is now

**Single writer: me.** Gemini and Claude are consults I ask, exactly like a web search -- they answer, I judge, I write. There is no second member, no dual-member dispatcher, and no PROPOSE fence contract. Those were abandoned; do not build them.

## Built, committed, tested

- `.system/vault-lib.ps1` -- 19 functions, every one reachable from the 7 exposed verbs (an AST reachability audit found exactly one orphan, `Get-VaultStats`, which was removed rather than left to rot).
- `.system/vault-adapter.ps1` -- verb dispatcher. One JSON object in on stdin (raw bytes decoded as UTF-8 by hand -- never `[Console]::In`, which uses the OEM codepage and turns em dashes into mojibake), one JSON object out on stdout.
- `.system/vault-mcp.mjs` -- MCP stdio server. One PowerShell spawn per tool call, ~0.5s, chosen over a long-lived process that would need crash recovery.
- `.system/smoke-test.mjs` -- read-only end-to-end test, safe to run any time. **17/17 passing.**
- Global `~/.config/opencode/opencode.jsonc` -- `edit` deny on the four content folders plus `CORE.md`, so note writes must go through the verbs. `.system/` is deliberately NOT denied (otherwise the library could never be maintained) and is still unreachable by any verb via `BlockedFolders`.
- Session protocol and the 7-day inbox rule live in `CORE.md`.

## Schema

Seven required: `name`, `description`, `aliases`, `status`, `updated`, `basis`, `scope`. Optional: `superseded_by`, `verified`.

- `basis` = `user-stated` | `observed` | `external-model` | `inferred`. It merged the old `source` + `confidence`.
- `verified` = `YYYY-MM-DD`, **required** whenever the note is about code or environment state.
- Dropped: `type` (the folder already says it, and two sources for one fact can disagree), `created` (git has it, with an author and a diff), `source`/`confidence` (both folded into `basis`).

## Verified working

- **Write-time validation** (25/25): a code-shaped note with no `verified` is refused, `verified: recently` is refused, `status: banana` is refused, and **no file is written on refusal**. Before this, the schema was advisory -- `New-VaultNote` never called the validator.
- **`-Set` whitelist**: `name`, `updated`, `created`, `type`, `author` are all rejected as non-mutable; a set changes only the named field and leaves the body untouched. This is how a note gets retired -- without it, `status: superseded` was unreachable and every note would live forever as `active`.
- Path guard 6/6 escape attempts rejected (`..`, absolute, `.obsidian`, `.git`, `.system`, unknown folder). Alias dedupe refuses collisions.
- UTF-8 round trip through stdin proven: em dash, curly quotes and accented e intact, no BOM, no U+FFFD.
- `recall` -> `read` round trip works. Retrieval used to return ABSOLUTE paths while `read` refuses them, so the very first navigation attempt dead-ended; `ConvertTo-VaultRelativePath` fixed it.
- Injection guard is **warn-only and scoped to `basis: external-model`**. The earlier "8/8 refused" figure proved little -- I wrote the patterns and the tests together -- and as a hard refuse it blocked ordinary coding memory such as "always use pnputil".

## Known gaps

- **No off-disk backup.** Local git on the same drive is not a backup. Unresolved.
- The MCP server is registered in config but OpenCode has not connected it yet -- confirm with `opencode mcp list` after a restart, then the 7 verbs appear as `vault_*` tools.
- Gemini/Claude consults are not wired back in as sources. Brave CDP on :9222 still works for a manual consult.
- The inbox drains by the 7-day rule surfaced by the `stale` verb; nothing drains it automatically.

## Not built

Consolidation/promotion pass -- embeddings or vector DB -- Obsidian as anything other than a human viewer. Its CDP graph path was **removed**: port 9223 is arbitrary code execution inside Obsidian, and grep was already fast enough.

## See also

[[Council memory substrate]] -- why plain markdown, and what was rejected.
[[Council write protocol]] -- the hygiene rules the verbs enforce.
[[Obsidian CDP access]] -- port map, and the obsidian.json BOM trap.
[[PowerShell text passing traps]] -- quoting/BOM/stdin encoding traps, all of which cost time here.
