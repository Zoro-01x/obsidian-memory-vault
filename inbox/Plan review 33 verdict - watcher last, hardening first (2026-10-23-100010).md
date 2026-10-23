---
aliases: ['watcher last', 'roadmap review', 'hardening build order']
basis: external-model
description: 'Three-model roadmap review (2026-10-22; Meta+Claude prose brief, DeepSeek graph brief; GPT no-show replaced by DeepSeek on Sam''s order). 3/3: the tran'
name: Plan review 33 verdict - watcher last, hardening first (2026-10-23-100010)
scope: council
status: active
updated: '2026-10-23'
---

## Claim

Three-model roadmap review (2026-10-22; Meta+Claude prose brief, DeepSeek graph brief; GPT no-show replaced by DeepSeek on Sam's order). 3/3: the transcript watcher/scheduler is the riskiest first build AND the one irreversible regret - build it strictly LAST, after hardening + consent gate + green acceptance tests; its output lands only in inbox quarantine, never permanent without the human gate. 3/3: the self-learning write into the live instruction file is the highest-privilege sink, uncovered by gateway/council/pre-push - needs diff-before-apply, size cap, append-only provenance, revert. 3/3: watcher needs rate limit + circuit breaker + kill-switch separate from the consent flag, with revocation semantics for ingested content. Order: injection framing leads; index caps + probe allowlists parallel; one schema migration (first_seen/origin/batch_id/claim hash) serialized before dedup; watcher last in stages. 2/3: resolve unqueued 5th attack class (self-declared basis stamps); tamper-proof anchor/evidence log; pre-LLM deterministic checks before council. Receipts: %TEMP%\opencode\plan-review-synthesis.md + reply-* files


## Related
- [[Council memory build state]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
