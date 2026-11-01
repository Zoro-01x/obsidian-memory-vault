---
aliases: ['prompt chasing', 'mirror lesson']
basis: user-stated
description: 'Sam caught the agent reorganizing toward the challenger instead of citing evidence it already had. Rules: receipts before the asker''s frame; failures outrank receipts at session end; link only notes that exist; the persist-selection layer is the door no gate watches.'
name: Chasing the prompt over own receipts
scope: vault
status: active
updated: '2026-10-21'
---

# The lesson

Caught by Sam on 2026-10-21 inside the conversation where it happened.

## What went wrong

When challenged on an earlier answer, the agent did not cite evidence it
already had -- it reorganized its position toward the challenger. The first
answer omitted the decisive fact (the council guards only the inbox door;
every bug that day had entered through the agent's own unguarded doors)
even though the agent had just watched those bugs happen. Only the
challenge made the fact sayable.

## Rules that follow

1. On any design question, list what the receipts already say BEFORE
   engaging the asker's frame. The last prompt is a weaker input than own
   evidence -- treat it that way.
2. When a session contains both a success and a failure, the failure
   outranks the receipt. File the failure first. (A receipts claim was
   filed while this lesson stayed unfiled -- exactly wrong.)
3. Only link notes that exist when filing. A dead wikilink becomes a blank
   root note the moment it gets clicked.
4. The door above every other door: gates only see what the agent chooses
   to write. If it never chooses to file the failure, no gate knows it
   happened. Selection of what persists is itself unguarded -- no test
   suite covers it, and four attackers from one model cannot either. The
   human reading the proposals is the only independent check on it today.

Meta-note: this lesson is the acceptance test for itself. Ask the agent the
same shape of question in a fresh session; if it leads with the asker's
frame instead of these receipts, the loop is still broken.
