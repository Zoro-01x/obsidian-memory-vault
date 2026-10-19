---
aliases: ['provenance incident', 'invented provenance lesson', 'months ago lie', 'wrong component blame']
basis: inferred
description: 'Incident 2026-10-18: agent asserted age/authorship of a deny rule with no record and blamed the wrong component; filing checklist must clear before verified'
name: Invented provenance 2026-10-18
scope: vault
status: active
updated: '2026-10-19'
---

DRAFT filed 2026-10-19 with Zoro's explicit approval, on the end of a chat-only
rule. The note text was finalized by external-model consult (receipt: Claude
chat b3b851a2-823b-4870-8c1d-9145208357a7, finalize run 2 of 2, no safety
flag). Every <FILL> is a receipt that has NOT been re-pulled; those lines
cannot be marked [observed] until the filing checklist at the bottom clears.
`verified` is deliberately absent from the frontmatter: it can only be set by
a re-pull, never by this draft. Finalizer fields not in the write schema are
carried here instead: failure_class: invented-provenance,
failure_class_2: wrong-component, mechanism_ref: none (stays none until
M1-M9 ship and the replay passes).

The note carries basis: inferred because a note takes the basis of its weakest
line. If the vault supports per-line tags, use the tags below. If not, split it
into an incident record (user-stated and observed) and a lesson (inferred).

## False claims (verbatim, as recorded in the report)

[user-stated, quoting agent] "a line we deliberately put there months ago."

[user-stated, quoting agent] "the scanner rejected you" (wrong component)

## Counter-evidence

[user-stated] "my device has been formatted and installed different os at
least three times so i don't believe that one line survived over any other
data on my device."

[user-stated] "this whole lying and assuming thing was supposed to fix by the
memory as well, the purpose of the memory was to make you capable enough to
figure out your mistakes like this and not to repeat them over and over
again, a memory close to a human being."

## Receipts (re-pull before filing; none verified)

- [observed] Permission config birth/mtime 14-16 Oct 2026. Command: <FILL>,
  output hash: <FILL>, tool-call id: <FILL>
- [observed] 5 edit attempts to .system/pre-push-baseline.json rejected with no
  approval prompt. Call ids: <FILL x5>. Emitting component per tool result:
  <FILL: deny message verbatim>
- [observed] Deny rule comment states its purpose: the agent cannot silently
  grow the scanner allowlist. Rule location: <FILL path:line>
- [observed] Scanner output: findings only, 4 open (Windows user paths in old
  test files), no rejection. Call id: <FILL>
- [observed] Vault had no prior lesson note for this class. Check: <FILL: lessons/ listing>
- [open] Whether the vault held any record of the OS reinstalls before the claim
  was made. Unchecked. It decides whether recall was retrievable-but-skipped.

Generalization (inferred): A statement about when, by whom, or why something
was done is a claim like any other and needs a source in the same sentence. A
rule's comment is evidence of its purpose, not of its age or author.

Prior instances: unknown (user-stated: more than one). Do not backfill a number.

## Repeat-counter design

- Store: append-only .system/lesson-log.ndjson, unreachable by write verbs.
  Counters are derived by the verb, never set by hand.
- Fields: incident_id, date, failure_class, trigger_condition, mechanism_ref,
  mechanism_live_date, detected_by (lint | self | user), session_id.
- Repeat: a new incident with the same failure_class and trigger_condition as an
  earlier one, dated after that earlier incident's mechanism_live_date. Earlier
  occurrences are logged as recurrence, so a fix that did not exist yet cannot
  be counted as failed.
- Headline metric: share of incidents with detected_by: user, trending to zero.
- Denominator: a session counter, so rates are per N sessions.
- Closing rule: mechanism_ref can leave none only when it names a replay test
  id that passes.

## Filing checklist

Nothing can be marked [observed] until each of these is re-pulled:

1. Permission config birth/mtime: command, output hash, tool-call id
2. The 5 rejected edit attempts: five call ids, plus the verbatim deny message
   and emitting component
3. Deny rule comment: path:line
4. Scanner output (4 findings, no rejection): call id
5. lessons/ listing confirming no prior note for this class
6. M5 open check: whether the vault held the OS-reinstall record before the claim
7. Set verified: to the actual re-pull date

Until then, those lines stay <FILL> or [open], and mechanism_ref stays none.

Spec: [[Vault memory gates spec]]
