---
aliases: ~
basis: observed
description: 'Single-writer protocol: basis provenance, supersession, dedupe, commit contract'
name: Council write protocol
scope: council
status: stale
updated: '2026-10-15'
---

## Rules

1. **Provenance.** Every note carries `basis` (user-stated / observed / external-model / inferred). One agent's inference never silently becomes fact.
2. **Supersession.** Reversed decisions get `status: superseded` plus `superseded_by`. Nothing is deleted.
3. **Dedupe on write.** Name and aliases checked first; duplicates refused with a link, not a silent merge.
4. **Single writer.** The harness is the only writer. Content enters the vault through the adapter, which enforces the schema, the folder allowlist and the commit contract. There is no second write path to reconcile with.
5. **Context budget.** CORE.md is hard-capped at ~1500 tokens. Every recalled byte is pasted into a prompt box and costs tokens.
6. **Commit contract.** A verb stages only the path it wrote (`Save-VaultCommit -Path`). `git add -A` is forbidden: it sweeps unrelated edits into a note-shaped commit, so the message stops describing the diff and the audit trail silently rots.
