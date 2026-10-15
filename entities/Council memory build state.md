---
aliases: ['handoff', 'build state', 'council progress', 'resume point']
basis: observed
description: 'Handoff: Phases 0-2 done, next is dual-member dispatcher. Read this to resume cold.'
name: Council memory build state
scope: council
status: active
updated: '2026-10-14'
---

## Where the build stopped

Phases 0-2 of the council memory design are **done and committed**. Phases 3-4 are **not started**.

Built:

- `.system/vault-lib.ps1` -- 12 constrained-verb functions (path allowlist, dedupe-on-write, atomic no-BOM writes, git commit with agent name, ripgrep retrieval, graph via CDP, budget-capped CORE).
- Vault folders: `inbox/ entities/ decisions/ lessons/` plus `CORE.md`.
- git repo initialised inside the vault; working tree clean.
- Tools on user PATH (no admin): git 2.56.0 + ripgrep 14.1.1, portable under `C:\Users\Home\tools\`.

## Verified working

- Path guard rejects 6/6 escape attempts (`..`, absolute, `.obsidian`, `.git`, `.system`, unknown folder).
- Injection guard refuses 8/8 instruction-shaped claims, allows 5/5 legitimate ones.
- Dedupe refuses a second note sharing an alias.
- `Get-VaultGraph` phantom-edge bug fixed (code spans now stripped); backlinks resolve.
- Obsidian sees every note and the full link graph via `app.metadataCache`.

## Next step -- agreed, not yet built

Wire **both** council members end to end, not just Gemini. Both chat tabs live on the same Brave endpoint (:9222); only Obsidian is on :9223. So a member entry needs a **tab URL pattern**, not a per-member endpoint.

Member registry -- two selectors differ per member, send/submit mechanism is identical:

- `gemini` -- tab `gemini.google.com`; composer `rich-textarea [contenteditable]` (Quill); reply `message-content`; busy = Stop-generating button.
- `claude` -- tab `claude.ai`; composer `div[aria-label*="Write your prompt"]` (tiptap); reply `[data-is-streaming]`; busy = `[data-is-streaming="true"]`.

Both accept `execCommand('insertText')` plus Enter dispatch.

Dispatcher: read CORE.md -> build prompt -> fresh tab per member -> inject -> submit -> poll to stability -> extract -> parse PROPOSE fence -> `Add-VaultInboxItem` -> return answer.

**Success criterion** is not "the model answered". It is: a file lands in `inbox/` with a valid `Test-VaultNote` result and a git commit naming the agent.

## Proposal contract (needs confirming)

Fenced block, typed header. Parser takes the first PROPOSE fence; everything outside it is the user-facing answer. No fence = no proposal filed, **not** a failed run.

    PROPOSE
    type: lesson
    title: short durable title
    claim: the durable fact, cause, or decision
    confidence: observed

## Known risk

Gemini has loose instruction-following and may not emit the fence cleanly. A missing fence must never surface as an error.

## Explicitly not built

Consolidation/promotion pass (inbox needs real content first) -- embeddings/vector DB -- MCP server -- Obsidian as a council *member* rather than the store.

## See also

[[Council memory substrate]] -- why plain markdown, and what was rejected.
[[Council write protocol]] -- the five hygiene rules the harness enforces.
[[Obsidian CDP access]] -- port map, metadataCache, and the obsidian.json BOM trap.
[[Intel UHD driver install]] -- the first lesson seeded into the vault.
