---
aliases: ['handoff', 'build state', 'council progress', 'resume point', 'current state']
basis: observed
description: 'Handoff: single-writer memory vault built, MCP connected, origin exists but one commit unpushed. Read to resume cold -- includes what was abandoned and why.'
name: Council memory build state
scope: council
status: active
updated: '2026-10-16'
verified: '2026-10-16'
---

## What this vault is now

**Single writer: me.** Gemini and Claude are consults I ask, exactly like a web search -- they answer, I judge, I write. There is no second member, no dual-member dispatcher, and no PROPOSE fence contract. Those were abandoned; do not build them.

## Reading this note safely

It records four different kinds of claim, and they go stale at different rates. Do not conflate them:

| Claim type | Example | How to recheck |
|---|---|---|
| A test passed at a point in time | smoke tests passing on the verified date | rerun the command |
| A service is connected right now | the MCP server | `opencode mcp list` |
| A backup contains the latest commit | origin sync state | `git status -sb` |
| A feature is not implemented | inbox auto-draining | read the code |

Test counts are deliberately **not** written into this note. They were stale within a week last time. Run the command; the expected outcome is "all pass, zero fail". A shrinking pass count is a finding, not noise -- investigate before updating anything.

## Built, committed

- `.system/vault-lib.ps1` -- the library. An AST reachability audit found exactly one orphan (`Get-VaultStats`), which was removed rather than left to drift.
- `.system/vault-adapter.ps1` -- verb dispatcher. One JSON object in on stdin (raw bytes decoded as UTF-8 by hand -- never `[Console]::In`, which uses the OEM codepage and turns em dashes into mojibake), one JSON object out on stdout.
- `.system/vault-mcp.mjs` -- MCP stdio server. One PowerShell spawn per tool call, chosen over a long-lived process that would need crash recovery.
- Global `~/.config/opencode/opencode.jsonc` -- `edit` deny on the four content folders plus `CORE.md`, so note writes must go through the verbs. `.system/` is deliberately NOT denied (otherwise the library could never be maintained) and is still unreachable by any verb via `BlockedFolders`.
- Session protocol and the 7-day inbox rule live in `CORE.md`.

**Added later, not described in the original handoff** -- these exist and matter:

- `.system/pre-push-scan.ps1` + `.system/pre-push-baseline.json` -- history scanner with detectors, plus an accepted baseline. Commit 752d945 accepts 12 known windows-path findings.
- `.system/vault-write-guard.ps1`
- `.system/migrate-schema.ps1` -- the frontmatter migration script.

The baseline of 12 accepted findings is a convenience for this **private** repo. It is not a clean bill of health, and it must NOT carry over to any public tooling-only repo.

## Tests -- run these, do not trust a remembered number

All three are safe. None writes to the real vault.

| Command | What it proves | Expected |
|---|---|---|
| `node .system/smoke-test.mjs` | read-only end-to-end through all 7 verbs | all pass, zero fail |
| `node .system/cold-start-test.mjs` | the wrapper works when OpenCode spawns it fresh, from a foreign cwd | all pass, zero fail |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .system/write-validation-test.ps1` | schema is enforced before writes; `-Set` respects its whitelist; a refusal stages and commits nothing | all pass, zero fail |

Run the cold-start test after **any** wrapper, config, or Node change. A wrapper can work in the session that built it and still fail cold.

**On the write-test count:** the source contains 35 `T` calls but executes 33 assertions, because 5 try/catch pairs run one branch each and the mutable-field check is a loop over 5 fields. The executed count has shifted across the isolation rewrite (commit 6fd75f9). Whether a specific assertion was removed or merged in that rewrite is **not yet confirmed** -- check `git log -p -- .system/write-validation-test.ps1` before making any claim about it.

## Verified working (what the tests establish)

- **Write-time validation**: a code-shaped note with no `verified` is refused, `verified: recently` is refused, `status: banana` is refused, and **no file is written on refusal**. Before this, the schema was advisory -- `New-VaultNote` never called the validator.
- **`-Set` whitelist**: `name`, `updated`, `created`, `type`, `author` are all rejected as non-mutable; a set changes only the named field and leaves the body untouched. This is how a note gets retired -- without it, `status: superseded` would be unreachable and every note would live forever as `active`.
- Path guard rejects escape attempts (`..`, absolute, `.obsidian`, `.git`, `.system`, unknown folder). Alias dedupe refuses collisions.
- UTF-8 round trip through stdin proven: em dash, curly quotes and accented e intact, no BOM, no U+FFFD.
- `recall` -> `read` round trip works. Retrieval used to return ABSOLUTE paths while `read` refuses them, so the very first navigation attempt dead-ended; `ConvertTo-VaultRelativePath` fixed it.
- **Commit isolation**: a verb stages only the path it wrote. An earlier `git add -A` bug bundled unrelated pending edits into a note-shaped commit.
- Injection guard is **warn-only and scoped to `basis: external-model`**. An earlier "8/8 refused" figure proved little -- the patterns and the tests were written together -- and as a hard refuse it blocked ordinary coding memory such as "always use pnputil".

## State as verified on 2026-10-16

- **MCP**: `opencode mcp list` reports `vault connected`, and all 7 verbs respond. (The previous version of this note said it was not connected. That was stale.)
- **Notes**: 6, all on the migrated schema, all carrying `basis:`.
- **Obsidian**: not running, port 9223 not listening. This does **not** affect the 7 verbs -- they do not need it. Only the human-viewer half is offline.
- **Git sync**: `main...origin/main [ahead 1]`. Local HEAD `a97db7d`, origin `a58c305`.
- **The note migration itself IS pushed.** The commit that moved notes onto the new schema is `2fe75c5`, an ancestor of `origin/main`. The unpushed `a97db7d` is **named** "[migrate] migrate frontmatter..." but touches **zero note files** -- it only changes `.system/cold-start-test.mjs` and `.system/migrate-schema.ps1`. Do not infer commit contents from commit titles; I did that once and it was wrong.

## Known gaps

- **Backup is not current.** Origin exists, but one commit is unpushed, so the off-disk copy does not contain the latest work. Pushing is a decision for Zoro -- it is the only external write in this system.
- Gemini/Claude consults are not wired back in as sources. Brave CDP on :9222 still works for a manual consult.
- The inbox drains by the 7-day rule surfaced by the `stale` verb; nothing drains it automatically. **Not built, by choice** -- do not "fix" this without asking.
- The 34->33 assertion question above is unresolved.

## Not built

Consolidation/promotion pass -- embeddings or vector DB -- Obsidian as anything other than a human viewer. Its CDP graph path was **removed**: port 9223 is arbitrary code execution inside Obsidian, and grep was already fast enough.

## See also

[[Council memory substrate]] -- why plain markdown, and what was rejected.
[[Council write protocol]] -- the hygiene rules the verbs enforce.
[[Obsidian CDP access]] -- port map, and the obsidian.json BOM trap.
[[PowerShell text passing traps]] -- quoting/BOM/stdin encoding traps, all of which cost time here.
