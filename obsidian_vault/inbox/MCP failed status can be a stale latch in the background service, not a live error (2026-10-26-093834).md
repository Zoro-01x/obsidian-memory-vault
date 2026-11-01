---
aliases: ['opencode mcp list stale failed status', 'mcp server failed cached', 'github mcp ENOTFOUND stale', 'service restart fixes mcp failed']
basis: observed
description: '2026-10-26: ''github MCP failed: getaddrinfo ENOTFOUND api.githubcopilot.com'' was a CACHED latch, not a live error.

Proof: config correct (opencode.js'
name: MCP failed status can be a stale latch in the background service, not a live error (2026-10-26-093834)
scope: 'machine (OpenCode background service, C:/Users/Home global config)'
status: active
updated: '2026-10-26'
---

## Claim

2026-10-26: 'github MCP failed: getaddrinfo ENOTFOUND api.githubcopilot.com' was a CACHED latch, not a live error.

Proof: config correct (opencode.jsonc wins; oauth:false + Bearer {env:GITHUB_MCP_TOKEN}, token present). A fresh Node initialize POST with that token returned HTTP 200 + full MCP handshake, so auth/config were fine. DNS healthy: dns.lookup 25/25 (15/15 post-flush), DnsOnly via 8.8.8.8 30/30, no proxy, hosts clean. Yet 'mcp list' said failed 3/3 while vault showed connected.

Decisive: opencode.log has ZERO github connect attempts on 10-26. Last real attempt was 2026-10-25T18:09:20Z in a ~2.3s retry burst that all hit a transient DNS outage. The service (PID 6116, up ~19.5h) latched 'failed' and never retried; 'mcp list' prints that latched state.

Rule: 'mcp list' is cached state, not proof of a fresh attempt. Grep the log for the last real attempt; if no new connect lines appear while reproducing, the fix is 'opencode service restart', not config/credential changes.


## Related
- [[GitHub MCP in OpenCode needs PAT header auth, OAuth cannot complete]]
- [[This machine's DNS is lossy git fails while TNCgh succeed]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
