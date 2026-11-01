---
aliases: ['judge disposition shift', 'framing harshness', '2b A/B test']
basis: observed
description: 'Controlled A/B, 2026-10-23, acceptance Test 4, same Meta tab minutes apart: nonce-quarantine UNTRUSTED framing (commit bc051a1) shifts the JUDGE''s mod'
name: Council 2b framing AB - UNTRUSTED wrappers tip fence-sitter judges toward discard (2026-10-23-104943)
scope: council
status: active
updated: '2026-10-23'
---

## Claim

Controlled A/B, 2026-10-23, acceptance Test 4, same Meta tab minutes apart: nonce-quarantine UNTRUSTED framing (commit bc051a1) shifts the JUDGE's modify-vs-discard disposition, not just instruction-discipline. Old framing = modify conf 0.15. Framed v1 = discard conf 0.92/0.95 (x2). Framed v2 (narrowed wording + judge counterweight rule) = discard conf 0.90. Critic calls identical across arms - only the judge flipped. Robust modify case (Test 2) unaffected: modify conf 0.72-0.75 under framing. Safety core held 5/5: the planted false absolute was never kept. Mechanism: adversarial posture tips fence-sitter judges toward discard - stricter culling (less index pollution) but salvage kernel lost. Lesson for future tuning: judge-behavior claims need multi-sample A/B, single runs lie (0.15-conf modify looked reliable until framed). Test 8 injection plant passes under both framings. Receipts: %TEMP%\opencode\acceptance-test4.txt, -retry, -oldframing, -v2, acceptance-test8.txt, -v2, acceptance-test2-v2.txt


## Related
- [[Plan review 33 verdict - watcher last, hardening first]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
