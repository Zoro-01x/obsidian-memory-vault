---
aliases: []
basis: user-stated
description: 'The Obsidian memory module is the long-term memory for AI agents like OpenCode — agents that have tool access and can act on the user''''s device. It is '
name: What the Obsidian memory module is for (2026-10-17-105734)
scope: vault
status: active
updated: '2026-10-17'
---

## Claim

The Obsidian memory module is the long-term memory for AI agents like OpenCode — agents that have tool access and can act on the user's device. It is not a note archive and not a knowledge base.

The user's stated purpose: so the agent can **learn, unlearn, and update over time** and become capable of complex tasks **without the user's constant attention** — in simple terms, developing a memory close to a human being, with the capability of self-learning, understanding, and applying.

Two consequences:

1. **Written for the agent, by the agent.** The reader is a future session of a tool-using agent, not the human. A note exists only if it changes what that future session does.
2. **Unlearning is first-class, not just addition.** The goal is accuracy, not growth — a wrong note that is never superseded gets confidently re-applied. `append`'s `set` (status: superseded, superseded_by) plus `stale` are the unlearning path.

Success condition: the agent completes a complex task correctly with no supervision, because it recalled a prior decision, lesson, or environment fact instead of rediscovering it or guessing. Feature requests get checked against this charter.


## Related
- [[CORE]]
- [[Council memory substrate]]
- [[Council write protocol]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)

Handed off to the permanent note [[Obsidian memory module]] — user-stated content does not belong in inbox.
