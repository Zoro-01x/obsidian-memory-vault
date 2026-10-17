---
aliases: ['dual list drift', 'two sources of truth', 'derived lists']
basis: observed
description: A hand-maintained duplicate of an existing list silently falls out of sync; derive it instead
name: Two lists that must agree will drift
scope: vault
status: active
updated: '2026-10-17'
verified: '2026-10-17'
---

## What happened

Adding the `verify` verb, I registered it in `TOOLS` in `.system/vault-mcp.mjs`
-- the catalogue that drives both `tools/list` and dispatch lookup. But the
file ALSO had a separate literal:

```js
const VERBS = ["core", "recall", "read", "create", "append", "propose", "stale"];
```

I missed it. Result: `tools/list` advertised `verify` correctly, and every call
returned *"Tool \"verify\" has no adapter verb."* The tool was visible and
unreachable -- the worst shape, because the failure surfaces at call time in a
different code path from the registration.

## Why it is worth remembering

This is the **two-sources-of-truth** failure this vault's own notes keep
warning about, sitting inside the very dispatcher that enforces the schema.
Naming a second list is what makes it possible: nothing forces the two to
agree, and nothing fails when they diverge.

The general form: any two literals that must stay equal, maintained by hand,
will eventually disagree. The fix is always the same -- **derive one from the
other** so disagreement is unrepresentable:

```js
const VERBS = TOOLS.map((t) => t.name);
```

## Where else this applies

Check for further instances before trusting this fix is complete:

- the probe-kind registry in `vault-lib.ps1` vs the `create` validator vs the
  MCP `enum` -- three places list the four probe kinds
- the `set` whitelist in `Update-VaultNote` vs the MCP schema's documented
  whitelist vs any blocked-key list
- the write-folder allowlist vs the adapter's `folder` enum

A test asserting each is derived from, or equal to, one source would catch the
next one before a dispatcher does.

## Related

- [[Vault verify verb]] -- where the bug surfaced.
