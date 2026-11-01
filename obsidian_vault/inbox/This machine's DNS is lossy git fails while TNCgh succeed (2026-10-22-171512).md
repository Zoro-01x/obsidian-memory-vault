---
aliases: ['DNS flaky', 'c-ares cache blind', 'github resolve host']
basis: observed
description: '2026-10-22: Wi-Fi 2 DNS = 8.8.8.8/8.8.4.4 with INTERMITTENT UDP53 loss - Resolve-DnsName timed out seconds after succeeding; 1.1.1.1 also timed out; n'
name: This machine's DNS is lossy git fails while TNCgh succeed (2026-10-22-171512)
scope: 'D:\Sam machine'
status: active
updated: '2026-10-22'
---

## Claim

2026-10-22: Wi-Fi 2 DNS = 8.8.8.8/8.8.4.4 with INTERMITTENT UDP53 loss - Resolve-DnsName timed out seconds after succeeding; 1.1.1.1 also timed out; no proxy, no VPN adapter, not elevated. Git (c-ares) ignores the Windows DNS cache and issues its own single-shot queries, so 'Could not resolve host' repeats even with a hot cache; Test-NetConnection and gh use the OS resolver/cache and can succeed on the same name. Working recipe: git config http.ipResolve 4 + bounded retry loop (6-10 attempts, 2-4s apart - first success usually attempt 3-6) + a background Resolve-DnsName prime loop over github.com, api.github.com, gist.github.com, codeload.github.com every 20s for OS-resolver tools. Rule: browser or TNC success never proves git success - report the exact probe.



## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
