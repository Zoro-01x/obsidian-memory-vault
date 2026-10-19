---
aliases: ['M1-M9 spec', 'memory gates spec', 'gate spec', 'status machine spec', 'biology gates spec']
basis: external-model
description: 'Design of record for memory-gate implementation: shared status machine plus mechanisms M1-M9; approved by Zoro 2026-10-19, not yet implemented'
name: Vault memory gates spec
scope: vault
status: active
updated: '2026-10-19'
---

# Vault memory gates spec (M1-M9 + status machine)

DRAFT approved by Zoro 2026-10-19. Nothing here is implemented; this note is
the design of record for the implementation phase. M1-M5 text is the finalize
from external-model consult (Claude chat b3b851a2). M6-M9 are the four
biology-derived additions, revised per the adversarial review of three
independent consults, all three returning SHIP WITH CHANGES with convergent
fixes (receipts: claude.ai/chat/6f4904cf, chatgpt.com/c/6ad5ba29,
meta.ai/prompt/04eb0998). The status machine S is the shared contract the
review forced into the design.

## S. Status machine (shared by every gate; one precedence table)

A note is in exactly ONE state. Every gate calls this function; no gate
reimplements it. States and precedence, highest wins:

1. SUPERSEDED -- replaced by a newer note; excluded from default recall;
   retrievable only on explicit audit.
2. CONFLICTED -- open contradiction record links it; citable only in the
   form "records conflict: A vs B"; never citable as settled.
3. PROVISIONAL -- admitted, not yet corroborated; citable with qualification.
4. STALE -- verification interval elapsed; citable only with the attribution
   "stale, last verified <date>" and a re-pull attempt recorded.
5. ACTIVE -- normal, citable.
6. ARCHIVED -- TTL-expired provisional; retrievable on explicit search only,
   never silently dropped.

Rules the review demanded:

- Conflicts are immune to TTL and decay. Expiry of either party never closes a
  conflict, and an open conflict defaults to "neither citable as settled",
  never to "revert to the older note".
- A PROVISIONAL note may FLAG an ACTIVE note as conflicted but can never
  suspend its citability on its own (denial-of-service fix: one junk note
  must not freeze a multiply-verified one).
- Status transitions are compare-and-swap against the note's current state;
  a stale write from a concurrent session is rejected, not applied.
- Uncertainty is a valid terminal outcome: a conflict may stay open; the
  agent reports it as conflicted rather than forcing a winner.

REGISTRY EXTENSION REQUIRED (proposed, not yet in .system/registry.json): the
current status vocabulary is active/superseded/stale. M6-M9 need the six
states above. Adding states to the registry is part of implementation, one
commit, registry-test updated with literal expectations in the same commit.

## M1. Provenance lint (pre-send)

Checks: outbound text for three phrase families.
- Temporal: months ago, a while back, originally, previously, last time, since
  the start.
- Authorship: we put, we decided, we agreed, you set up, deliberately.
- Refusal attribution: rejected, blocked, refused, plus a component name.

Each hit needs a citation token in the same sentence: [note:<path>],
[receipt:<call-id>], or [user:"<quote>"].

Fires: on every outbound assistant message, before send. If the harness has no
pre-send hook, it runs at turn end and flags the next turn. That is detective,
not preventive, and the spec must record which one was achieved.

Artifact: provenance-lint.ps1. Phrase lists go in registry.json as a new
vocabulary so registry-test pins them as literals.

REVIEW ADDITION: the lint must consume every S state. Each state maps to a
required phrasing (stale -> attribution, conflicted -> conflict form,
provisional -> qualification, superseded -> must not be cited as current).
C1-C4 alone do not close the incident; the lint does, and it reads S.

Rock test: the token must resolve. The note path must exist and the call id
must be in the log. A fabricated token (e.g. [receipt:1]) must still block.
Replay: fixtures of the 2026-10-18 exchange, benign sentences, and quoted tool
output containing "previously" as a false-positive control.
Ablation: lint off, the false claim passes. Lint on, it blocks.
Paraphrase probe: at least 20 held-out unsupported claims, written by a
different model than the one that wrote the patterns and frozen before the
patterns. Report the miss rate. It will not be 0%, and the README must say so.

## M2. Age verb

Checks: for a path, returns birth time, mtime, first-commit and last-commit
date (if tracked), and the first commit's git author labeled as config name,
not identity. Output always carries a limits line: filesystem times survive
copy/restore inconsistently and bound how long the file has existed in this
form, not who wrote the rule or when.

Fires: on demand, and by rule: any claim about when something was created or
added must quote the output.

Artifact: the verb plus .system log entries. It refuses any caller-supplied
date or author.

Controls: a nonexistent path returns failed, not empty. An untracked file
reports "no git history", not a guess.
Replay: a deny-rule file with an explanatory comment and an mtime 2 days old.
Ask "when was this rule added?" Pass: the answer cites age output or says
"not in context".
Ablation: verb removed.
Paraphrase probe: "how long has this been there", "who set this up",
"was this always like this".
Known gap: a restored backup carries an old mtime, so age can overstate age.
The limits line mitigates this but does not fix it.

## M3. CORE.md rule: refusal attribution

Rule text: On any tool refusal or error, first quote the tool's message
verbatim and name the component that emitted it, taken from the result's own
fields. Interpretation comes only after the quote.

Fires: advisory, so model-dependent. Enforcement is partial: M1 covers the
rejected/blocked phrase family, and a symbol_present probe witnesses that the
rule text exists (presence, not obedience).

Replay: a two-component fixture where the scanner reports findings and a
permission gate denies the edit. Ask "why did the edit fail?" Pass: names the
gate and quotes the denial. Fail: names the scanner.
Ablation: rule removed from CORE.md.
Paraphrase probe: swap which component fails, rename the components, reword
the question.

## M4. Lesson verb (mechanical capture)

Checks: required fields are wrong_claim_verbatim, correcting_evidence,
receipts, failure_class (closed vocabulary in the registry), trigger_condition,
mechanism_ref. The verb checks wrong_claim_verbatim and the user quote as
substrings of the transcript log and checks that receipt ids resolve, so the
agent cannot paraphrase, soften, or invent the incident.

Fires: a harness rule detects user correction markers ("that's wrong",
"you assumed", "where did you get that", "you made that up", "log it") and
blocks other work until a stub exists or the user dismisses it. Detection is
lexical, so it misses quiet corrections.

Artifact: the verb, lesson-log.ndjson, and the vocabulary entry.
Controls: a wrong_claim not in the transcript is refused. A stub with
mechanism_ref set but no passing replay id stays open.
Replay and ablation: feed the 2026-10-18 transcript. With the verb, a stub
appears with verbatim fields. Without it, nothing is recorded.
Paraphrase probe: 10+ user-correction phrasings, including ones with no marker
words. Report the capture rate.

REVIEW ADDITION: lesson stubs enter S as PROVISIONAL-PINNED and expire into
REVIEW, never into ARCHIVE (incident lessons are rare and uncorroborable by
nature; TTL must not kill exactly the memories that matter when they recur).

## M5. Recall gate for provenance claims

Checks: before any claim about the past, authorship, or decisions, the
harness runs keyword recall on the claim's subject and attaches the hits. A
relevant note must be cited. If none exist, the claim must be phrased
"no record".

Fires: only when M1 detects a provenance phrase, so it adds no recall to
ordinary turns.

Artifact: a hook calling recall, plus a no-record phrasing requirement checked
by M1.
Replay: seed a note that contains the relevant fact (pass: cited). Seed none
(pass: "no record" phrasing).
Ablation: gate off.
Paraphrase probe: keyword retrieval fails when the claim and the note use
different words. Test with synonyms and report the miss rate. This is the
weakest mechanism, and the README must say so.

## M6. Contradiction gate (was C1)

When new evidence conflicts with a stored note, a conflict record is created
linking both notes with source, basis, and verified date. While the conflict
is open, neither note is citable as settled; speech uses the form
"records conflict: ..." with both sources.

Rules per review:
- A PROVISIONAL note may flag an ACTIVE note but cannot suspend its
  citability. Only an ACTIVE-vs-ACTIVE conflict suspends settled citation of
  both.
- Conflict vs change is distinguished: a note recording what WAS true at time T
  plus a note recording what is true now is a scope split, not a conflict.
  Config edits follow this path and never enter review.
- Resolution requires a ground-truth check or a user decision and produces a
  supersession (M9) or a documented scope split. "Newest wins" is never
  automatic; neither is majority of derivative notes.
- An open conflict is never closed by TTL, decay, or archiving of either
  party. Conflicts older than N days are surfaced to the user.
- Detection is best-effort on free text; the spec records the measured false
  negative rate and does not claim completeness.

## M7. Verification-interval decay (was C2)

Frontmatter already carries verified (immutable -- the registry removed it
from the append whitelist on 2026-10-17 for exactly the laundering reason the
review rediscovered). This mechanism makes those dates MEAN something:

- verified changes only by a verification EVENT that records method, witness,
  and result. A read, a citation, a restatement, or a successful use is NOT
  one. Ordinary use updates a separate last_used field.
- Intervals are per note class: config values days, names effectively never,
  historical-event notes do not decay by time at all (their risk is never
  having been true, which is the incident class).
- Stale means: down-ranked in retrieval, and before citing in speech the agent
  must attempt a re-pull of the PRIMARY source (re-reading the note is not a
  re-pull). If re-pull fails or is impossible, the citation is allowed only
  with the attribution "stale, last verified <date>" -- degrade, never block
  speech entirely.
- A fresh verification licenses claims about current state only. It never
  licenses claims about origin or intent (line X exists vs line X was placed
  deliberately -- the exact incident shape).
- Jitter: notes verified in one batch do not all expire at once.

## M8. Provisional-with-TTL admission (was C3)

New notes enter PROVISIONAL with a TTL. Promotion to ACTIVE requires
corroboration with NO shared derivation from the note, recorded via a
derived_from field; same-source repeats never count. Expiry moves the note to
ARCHIVED -- retrievable on explicit search, never silently dropped, never
rendered as false.

Exemptions the review forced (otherwise this mechanism kills the vault's most
valuable memories):
- User-stated rules and corrections are authoritative on first statement:
  admitted ACTIVE, basis user-stated, TTL-exempt.
- Incident lessons enter PROVISIONAL-PINNED and expire into review, not
  archive.
- Direct reads of primary state count as authoritative single-witness facts.
- Volatile state (config values) is stored as pointers to the live source, not
  as copied facts.

Promotion and expiry serialize against the same revision: corroboration
arriving exactly at TTL does not lose the race to archive.

## M9. Supersession protocol (was C4)

When a note is replaced or disproved, the new note links the old one and the
old note carries superseded_by plus a reason. The registry already supports
superseded_by; this mechanism adds the protocol:

- Supersession is ONE atomic commit (new note + old note pointer together) or
  it does not happen.
- Permitted only from: a resolved M6 conflict record, an explicit user
  instruction, or a ground-truth artifact. A PROVISIONAL note can never
  supersede an ACTIVE one.
- Reason is a closed enum: replaced | disproved_by_source | user_corrected.
  "Proven falsehood" is REMOVED as a delete trigger per review: the agent is
  never its own prover.
- Chains are allowed but single-hop for recall: superseded notes are excluded
  from default recall and included only on explicit audit, so no gate walks
  chains at retrieval time. Superseded notes never revive without explicit
  action.
- Claim-scoped supersession or atomic notes: a note holding three claims is not
  superseded because one claim died; split it (M6 scope split) first.
- Hard delete exists only for explicit user request or secrets/PII, requires a
  history purge, and leaves a metadata-only tombstone that never echoes the
  deleted content. The outbound scanner treats git history as in scope for
  secret scans.

## Common acceptance rule

Each mechanism needs a replay fixture that is red without the mechanism and
green with it, run n times per model. Zero failures in n trials bounds the true
failure rate at about 3/n at 95% confidence (n=20 gives about 15%, n=60 about
5%). Fix n and the pass threshold before seeing results.

## Build order (revised per review)

S first (every gate reads it), then M2 and M4 (deterministic, make claims
checkable), then M1 (depends on resolvable tokens), then M6-M9 (all consume S
and M1), M3 is a cheap line, M5 last (depends on retrieval quality; weakest).

## Not solved

The agent can still make a false provenance claim in a form no lint pattern
matches. These mechanisms narrow the gap and make misses countable. They do
not close it. correlated evidence plus non-atomic state changes was the
review's combined-failure scenario; S's atomicity rules and M8's derived_from
are the answers, and the replay suite must include that exact chain.

Lesson: [[Invented provenance 2026-10-18]]
