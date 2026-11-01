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

---

## RESOLVED 2026-10-17 (commit `aa1b808`)

The class, not just the instance, is now fixed. **`.system/registry.json`** is the
single source of truth for 14 closed vocabularies; both `vault-lib.ps1` and
`vault-mcp.mjs` derive from it.

**Inventory found six MORE duplicated vocabularies, and one had already
drifted:** `WriteFolders` had four entries (incl. `inbox`) while the MCP
`create` enum had three. That one is *deliberate* -- `propose` calls
`New-VaultNote -Folder 'inbox'`, and exposing inbox on the MCP create enum
would let an agent bypass the inbox review queue. But nothing said so, so a
deliberate design was indistinguishable from a bug. It is now two **named**
lists (`writeFolders` / `createFolders`) with the reason written into the file.

> **The generalisation worth keeping:** the value of a registry is not only
> catching drift. It is **making a deliberate difference explainable**. Before,
> you had to ask a human whether a divergence was intended. Now the answer is
> in the file.

**Four `[ValidateSet]` attributes were removed** from `New-VaultNote` /
`Add-VaultInboxItem`. `ValidateSet` is evaluated at *parse* time and cannot
read a variable (`IValidateSetValuesGenerator` is PowerShell 6+, not Windows
PowerShell 5.1), so it was structurally incapable of deriving -- a third and
fourth copy of the same vocabularies. Runtime guards reading the registry
replace them, and the error message improves as a side effect: it now lists the
allowed values.

**The startup check.** `VERBS` is still derived from `TOOLS`, and the two are
now compared against the registry by **set equality at startup**. A mismatch
exits 1 printing both lists. The original bug cost a debug cycle because it
surfaced *per call*, far from the line that was wrong; failing at startup puts
the message next to the cause.

**Fail closed.** A missing, malformed, keyless or empty-list registry refuses
to load, on both the PowerShell and Node side. A *defaulted* registry would
enforce the wrong vocabulary, which is worse than enforcing none. Consequence
worth knowing: **`registry.json` is now a hard runtime dependency** -- a clone
missing it gets a startup refusal, by design.

### The part to defend hardest

The guard suite (**`.system/registry-test.ps1`, 55/55**) pins every expectation
as a **literal**, never read back from the registry. Claude's reasoning, and it
is the same rock-test logic applied to `verify`, one level up:

> "If the test builds its expected value from the manifest, it's tautological --
> editing the manifest edits the test with it."

So the suite has two kinds of check that fail differently on purpose:
consistency checks (both sides compared -- pass for any well-formed registry)
and **literal checks** (registry compared to a hard-coded list -- fail when
someone adds a fifth probe kind). That second failure is the point: it forces a
human to confirm an addition rather than letting it arrive silently.

**Related:** [[Vault verify verb]] -- where the bug surfaced.
