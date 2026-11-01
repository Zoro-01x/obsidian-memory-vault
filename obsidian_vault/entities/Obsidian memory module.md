---
aliases: ['memory module purpose', 'vault charter', 'why the vault exists', 'self learning memory']
basis: user-stated
description: Charter for the Obsidian memory module — long-term memory for tool-using AI agents, so they can learn, unlearn and act without constant supervision.
name: Obsidian memory module
scope: vault
status: active
updated: '2026-10-17'
---

The memory module is the long-term memory for AI agents like me — agents that
have tool access and can act on the user's device. It is **not** a note archive
and **not** a knowledge base.

## Purpose (user-stated, 2026-10-17)

So the agent can **learn, unlearn, and update over time** and become capable of
handling complex tasks **without the user's constant attention**. In simple
terms: the agent develops a memory close to a human being, with the capability
of **self-learning, understanding, and applying**.

## What that implies

1. **Written for the agent, by the agent.** The reader is a future session of a
   tool-using agent, not the human. A note belongs here only if it changes what
   that future session does or says.
2. **Unlearning is first-class, not just addition.** The goal is accuracy, not
   growth. A wrong note that is never superseded gets confidently re-applied by
   a later session — so `append`'s `set` block (status: superseded,
   `superseded_by`) and the `stale` sweep are the retraction path, and they
   are as important as writing.
3. **It buys independence, not convenience.** The success condition is the agent
   finishing a complex task correctly with no supervision, because it recalled
   a prior decision, lesson, or environment fact rather than rediscovering it
   or guessing.

## Charter test for feature requests

If a change does not help a future session **learn, unlearn, or apply** without
supervision, it does not belong in the vault.

## Related

- [[CORE]] — the always-loaded index that states the session protocol.
- [[Council memory substrate]] — why plain markdown + wikilinks, no vector DB.
- [[Council write protocol]] — the single-writer rule and `basis` provenance
  that makes unlearning auditable.
