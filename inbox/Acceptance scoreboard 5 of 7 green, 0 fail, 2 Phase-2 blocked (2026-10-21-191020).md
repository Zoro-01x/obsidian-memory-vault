---
aliases: ['7 break tests scoreboard', 'acceptance suite green']
basis: observed
description: 'The 7 break tests from Sam''s Meta thread ran as a real pass/fail suite against the live vault (2026-10-21): Tests 1-4 (the lie, the contradiction, the'
name: Acceptance scoreboard 5 of 7 green, 0 fail, 2 Phase-2 blocked (2026-10-21-191020)
scope: vault
status: active
updated: '2026-10-21'
---

## Claim

The 7 break tests from Sam's Meta thread ran as a real pass/fail suite against the live vault (2026-10-21): Tests 1-4 (the lie, the contradiction, the noise, the useful nuance) all PASS end-to-end through the four-critic council on Meta chat; Test 7 (low-trust resurrection) PASS as a structural check; Test 5 (forced MCP recall prompt) and Test 6 (trust decay meta-rule) reported honest-RED as blocked until Phase 2 lands. Full run: 5 pass, 0 fail, 2 blocked of 7 in 357s. Two fixes were required to get there: the judge rule (salvageable insight inside a wrong framing must MODIFY, not discard, per Meta's spec) and region-scoped freshness (stale markers may legitimately live in sidebar history titles). Suite lives in .council/tests/acceptance.ts and accepts a single test id for cheap re-runs.



## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
