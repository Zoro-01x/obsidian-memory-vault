---
aliases: ~
basis: observed
description: Scripts with `$N`/`$n` collision or missing param $ silently fail; always use distinct param names and check variable scope
name: PowerShell variable case-insensitivity + missing $ can silently corrupt scans
scope: machine
status: active
updated: '2026-10-26'
verified: '2026-10-26'
---

- 2026-10-24 session: PowerShell variable-case bug (`$A`/`B` vs params) caused timeout; missing `$` on two variables caused another retry
- 05:28 discovered `$N` and `$n` referred to the same variable (PowerShell is case-insensitive)
- Script silently corrupted a blocked-scan before the bug was caught
- Pattern: always verify param names are truly distinct; prefer explicit naming over positional; check `$env:PSVersion` awareness when writing Windows automation
