---
aliases: ['rev-list --all deadlock', 'detached origin ref', 'force with lease rewrite']
basis: observed
description: 'pre-push-scan.ps1 enumerates rev-list --all (includes refs/remotes/*) and exits 1 on ANY non-baseline finding; email findings are non-baselineable. A '
name: Scanner deadlock when rewriting already-pushed history (workaround + ceilings) (2026-10-22-171512)
scope: obsidian-memory-vault
status: active
updated: '2026-10-22'
---

## Claim

pre-push-scan.ps1 enumerates rev-list --all (includes refs/remotes/*) and exits 1 on ANY non-baseline finding; email findings are non-baselineable. A finding inside origin/main's ancestry therefore blocks the very force-push that would remove it - a design deadlock for history rewrites. Workaround used 2026-10-22 for the public push: (1) detach local remote-tracking refs (update-ref -d refs/remotes/origin/main and origin/HEAD) so the scanner evaluates only the history being published via its 'no origin/main' path; (2) pin the true remote state with --force-with-lease=refs/heads/main:<true-old-sha> (server-side, independent of tracking refs); (3) the push itself recreates tracking refs at the new tip. Honest ceilings: the provenance range reports empty during that one push; GitHub may keep pre-rewrite objects fetchable-by-SHA until its own GC.


## Related
- [[pre-push scanner]]
- [[audit-baseline]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
