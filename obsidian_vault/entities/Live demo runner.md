---
aliases: ['demo.ps1', 'live demo', 'one-command demo', 'sabotage phase']
basis: observed
description: demo.ps1 runs the whole proof live from a fresh GitHub clone -- one command for showing the vault end to end
name: Live demo runner
probe_kind: path_exists
probe_target: demo.ps1
scope: vault
status: active
updated: '2026-10-18'
verified: '2026-10-18'
---

One command, nothing pre-computed: `powershell -NoProfile -ExecutionPolicy Bypass -File demo.ps1` (repo root).

Phases: (1) fresh clone from GitHub into %TEMP% -- local-repo fallback only if GitHub is unreachable, printed loudly, never silent; (2) all six suites against the clone, streaming; (3) adversarial demo; (4) with/without claim demo; (5) sabotage -- flips both status guards back to case-insensitive (the real historical defect), shows registry-test RED at 94/97 with exactly the three wrong-case status assertions named and CONTROL rows green, restores from git, shows 97/97; (6) verdict: clone HEAD and real vault HEAD unchanged, nothing pushed.

Verified 2026-10-18 by full run: exit 0 in 179s; clone HEAD 9ad76e1 = origin/main; suites green (registry 97, verify 77, write-validation 37, native-stderr 18, smoke 17, cold-start 8), adversarial 32/32, with/without 8/8. Flags: -Quick skips the five supporting suites, -Keep keeps the clone, -Source overrides the URL. Exit 0 means every phase behaved as expected including the catch; a green suite after sabotage would be reported as demo failure.

Deliberately NOT in the demo: the pre-push scanner -- it had 4 pending windows-user-path baseline entries (machine paths in old test files, not secrets) and wiring a red scanner into a live demo would be dishonest. The 2 email findings were cleared the same day by adding the project's own synthetic identity domain (vault.local) to $ReservedDomains in pre-push-scan.ps1; email findings are never baselinable. Recorded as of 2026-10-18, the day of the verified run; demo.ps1 and the README live-demo section were new and pending commit at record time.

Why it exists: a transcript proves nothing (anyone can paste green output), so the demo must be watchable live in front of a skeptic.
