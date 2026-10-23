---
aliases: ['github mcp auth', 'github mcp oauth failed', 'GITHUB_MCP_TOKEN', 'mcp needs authentication github']
basis: observed
description: 'opencode mcp auth github fails with ''does not support dynamic client registration''; fix is PAT in GITHUB_MCP_TOKEN env var + oauth:false header'
name: GitHub MCP in OpenCode needs PAT header auth, OAuth cannot complete
scope: 'machine (OpenCode global config, D:\Sam toolchain)'
status: active
updated: '2026-10-23'
verified: '2026-10-23'
---

## Symptom
`opencode mcp list` showed `⚠ github needs authentication` for the remote server
https://api.githubcopilot.com/mcp/ (configured in
C:/Users/Home/.config/opencode/opencode.jsonc). `opencode mcp auth github`
failed with: "Incompatible auth server: does not support dynamic client
registration".

## Cause (verified 2026-10-23)
GitHub's hosted MCP server supports browser OAuth for its own clients and PAT
header auth, but publishes NEITHER dynamic client registration NOR CIMD.
OpenCode needs one of those (or a pre-registered client_id it doesn't have),
so its OAuth flow can never complete. Machine git/gh auth was never the
problem: gh api user and git ls-remote both worked throughout.

## Working recipe
GitHub's documented PAT path:
1. Sam creates a classic PAT (repo, read:org, gist) at
   github.com/settings/tokens/new.
2. Token stored ONLY in the Windows user env var GITHUB_MCP_TOKEN:
   [Environment]::SetEnvironmentVariable('GITHUB_MCP_TOKEN','<token>','User')
3. Config entry: "oauth": false + headers Authorization:
   "Bearer {env:GITHUB_MCP_TOKEN}" -- no secret in any file.
4. Restart the OpenCode service so it inherits the new env var.

## Proofs
- Direct MCP initialize with Bearer token: HTTP 200 + full tools handshake.
- After service restart: `opencode mcp list` -> "✓ github connected", and
  tools.github.get_me() returned login Zoro-01x.

## Trap
If the PAT expires, the MCP silently goes stale -- re-create the token and
re-run step 2; no config change needed.
