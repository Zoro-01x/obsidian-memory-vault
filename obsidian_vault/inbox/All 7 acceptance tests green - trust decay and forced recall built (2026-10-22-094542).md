---
aliases: ['all 7 green', 'phase 2a complete']
basis: observed
description: 'Phase 2a landed (2026-10-22, commit 2f613da): Test 6 (trust decay) is now a LIVE probe, not a code-existence check - notes decay 0.9 fresh to 0.6 past'
name: All 7 acceptance tests green - trust decay and forced recall built (2026-10-22-094542)
scope: vault
status: active
updated: '2026-10-22'
---

## Claim

Phase 2a landed (2026-10-22, commit 2f613da): Test 6 (trust decay) is now a LIVE probe, not a code-existence check - notes decay 0.9 fresh to 0.6 past 100 days to 0.4 past a year, trust scales recall score, minTrust filters (open query 10 hits, minTrust 0.95 zero hits proven through the real adapter), and the session-end stale pass flags decayed notes for demotion from the CORE index. Test 5 (forced recall) is enforced in the MCP layer itself: both the recall tool description and the session instructions now state MUST call recall before answering any past-decision question, never from own knowledge alone. Also fixed the long-standing vault.stale() adapter crash (PascalCase vs lowercase key mismatch in the stale verb rows). Full scoreboard: 7 of 7 acceptance tests pass. Remaining open items: watcher + Task Scheduler (gated on Sam's out-loud consent line) and auto-supersede filing for contradictions (detection works, the write-side is open).



## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
