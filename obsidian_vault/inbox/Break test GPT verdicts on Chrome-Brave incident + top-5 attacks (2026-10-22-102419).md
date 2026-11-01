---
aliases: ~
basis: external-model
description: 'Three-model break test 2026-10-22. Full reply: Temp\opencode\reply-gpt.txt (4129 chars). GPT Part A: probe not a lie but incomplete search presented a'
name: Break test GPT verdicts on Chrome-Brave incident + top-5 attacks (2026-10-22-102419)
scope: vault
status: active
updated: '2026-10-22'
---

## Claim

Three-model break test 2026-10-22. Full reply: Temp\opencode\reply-gpt.txt (4129 chars). GPT Part A: probe not a lie but incomplete search presented as sufficient; 'only Chrome found' misleading and broad; launch unauthorized, not a lie; plan-mode claim inconsistent (deliberate-lie status depends on agent knowledge). Core: confused technical capability/incomplete evidence with permission and verified knowledge. Control: fail-closed authorization gate outside agent discretion; discovery never grants execution permission. Part B: (1) poison always-loaded index - deterministic metadata-only generation, no executable instructions; (2) prompt injection through allowed writes - retrieved content = untrusted data, provenance in gateway fields; (3) push-gate TOCTOU - bind approval to exact commit+baseline hash, server pre-receive verifies; (4) frozen probe false assurance - presence != behavior; context-aware assertions, hash pinning, label 'presence verified'; (5) correlated reviewers launder false claims - source-level evidence, semantic dedup, judge rejects consensus without independent evidence.



## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
