---
aliases: ['filter-branch scrub', 'tree-filter bug', 'Replace C with o']
basis: observed
description: '2026-10-22 public-push scrub: a git filter-branch --tree-filter script looping `foreach ($pair in @(@(''old'',''new'')))` silently flattened the nested ar'
name: PowerShell pair-array flattening mangled a history scrub (gate caught it) (2026-10-22-171512)
scope: obsidian-memory-vault
status: active
updated: '2026-10-22'
---

## Claim

2026-10-22 public-push scrub: a git filter-branch --tree-filter script looping `foreach ($pair in @(@('old','new')))` silently flattened the nested array, so $pair bound to each STRING and $pair[0]/$pair[1] indexed CHARACTERS. Result: .Replace('C','o') ran across the email note and .Replace('C',':') across two others, mangling 33 commits AND leaving the address alive as a corrupted-first-letter address variant, which the whole-history scanner blocked. Fix: direct sequential .Replace calls on string variables (no pair arrays), and unit-test the filter script against scratch files using the EXACT target filenames before any rewrite - my first unit test used wrong filenames and falsely 'passed' as a no-op. The pre-push scanner is the safety net that caught the silent corruption.


## Related
- [[pre-push scanner]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
