---
aliases: ~
basis: external-model
description: 'Synthesis of Meta/GPT/Claude break replies (2026-10-22; full text Temp\opencode\reply-*.txt). Convergent 3/3: 1. Always-loaded index = single point of'
name: Three-model break test convergent gap ranking (2026-10-22-102445)
scope: vault
status: active
updated: '2026-10-22'
---

## Claim

Synthesis of Meta/GPT/Claude break replies (2026-10-22; full text Temp\opencode\reply-*.txt). Convergent 3/3: 1. Always-loaded index = single point of failure (instruction poisoning + overflow DoS). Fix: deterministic metadata-only index, size cap, untrusted-data rendering, top-K retrieval. 2. Council prompt injection - candidate text read as instructions by reviewers. Fix: delimited-data framing + injection plants in acceptance tests. 3. Probes prove presence not truth + path escape to arbitrary files. Fix: probe path allowlist, hash-pinned targets, 'presence verified' label, probes never raise trust. 4. Freshness laundering - near-duplicates reset 0.9 age while truth decays; inbox flood beats human gate. Fix: content-hash dedup, first-seen age, inbox caps, trust = verification x age. Convergent 2/3: 5. Self-declared basis stamps can lie - gateway derives basis from checkable evidence, default inferred. Part A control 3/3: fail-closed no-substitution gate - no launches/tool calls outside allowlist without explicit approval; report exact commands+stdout. Solo but cheap: push TOCTOU - bind approval to commit hash (GPT); homoglyph collision - NFKC+confusable map (Meta).



## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
