"""test_scope.py - Day 17-19 acceptance: scope needs 3 parts + a mechanism.

AGENTS.md 10.12: scope = primary + transferable + unconventional. The
unconventional part must explain the cross-domain MECHANISM (biology ->
mechanical, like scientists reusing a biological insight to build an engine).
Bare domain names, or "applies to everything" without a mechanism, are
rejected as overgeneralization / hallucination (10.4.2).

Run:  python test_scope.py
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import vault_lib as V  # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}"
          + (f" -> {detail}" if detail else ""))


ACCEPT = {
    "AGENTS.md 10.12 coordinate-clicks example (mechanism shown)":
        ("primary: ixigo booking tab clicks | "
         "transferable: React site automation - same synthetic-vs-real user "
         "action mechanism | "
         "unconventional: Testing - Chrome tests fail with synthetic events, "
         "bot detection needs human-like coordinates (biology: human hand "
         "movement -> mechanical: engine/test bot)"),

    "full 3-part scope with an explicit 'via the same mechanism'":
        ("primary: daily INDEX rebuild for the obsidian vault | "
         "transferable: catalog generation for any approved-only dataset, "
         "same allowlist filter mechanism | "
         "unconventional: publishing - a newspaper presses only stories that "
         "passed the editor's gate, via the same allowlist mechanism"),

    "mechanism expressed as a 'domain: explanation' clause":
        ("primary: vault secret redaction by precise regex | "
         "transferable: log scrubbing pipelines, same match-then-replace "
         "mechanism | "
         "unconventional: luggage screening - scanners look for known "
         "contraband shapes, not every bag: keyword detectors work the same "
         "way, by signature rather than by understanding"),
}

REJECT = {
    "missing part (no transferable)":
        ("primary: ixigo booking tab clicks | "
         "unconventional: Chrome tests and bot detection need human gesture "
         "because biology maps to mechanics"),

    "unconventional = bare domain names, no mechanism":
        ("primary: ixigo booking tab clicks | "
         "transferable: React site automation, same synthetic action "
         "mechanism | "
         "unconventional: chrome tests bot detection kiosk gestures"),

    "unconventional = Sam's shorthand example, mechanism omitted":
        ("primary: ixigo booking tab clicks | "
         "transferable: React lazy cards, same scroll-then-click mechanism | "
         "unconventional: Chrome tests + bot detection human gesture"),

    "universal claim without a mechanism (10.4.2 overgeneralization)":
        ("primary: vault redaction of secrets | "
         "transferable: log scrubbing, same regex mechanism | "
         "unconventional: applies to everything everywhere in all domains "
         "since the mechanism is obvious"),

    "primary scope too vague (not a real domain)":
        ("primary: stuff | "
         "transferable: other stuff, same mechanism | "
         "unconventional: machines behave like animals because both are "
         "driven by feedback loops"),

    "unconventional is one line with no explanation at all":
        ("primary: vault read verb path checks | "
         "transferable: file API validation, same containment mechanism | "
         "unconventional: security"),
}

PROPOSAL_CASES = [
    ("propose() rejects a mechanism-less scope (10.12 at the door)",
     dict(claim="scope shorthand without a mechanism must not be stored",
          source="agent observed it",
          evidence="path: D:/Aariv/Learning Python/build_index.py | "
                   "excerpt: from vault_lib import SECRET_REGEX, VAULT, "
                   "priority_of",
          scope=("primary: ixigo booking tab clicks | transferable: React "
                 "site automation same mechanism | unconventional: chrome "
                 "tests bot detection human gesture")),
     False),
    ("propose() accepts the same claim once the mechanism is written",
     dict(claim="scope shorthand gains acceptance once mechanism is written",
          source="agent observed it",
          evidence="path: D:/Aariv/Learning Python/build_index.py | "
                   "excerpt: from vault_lib import SECRET_REGEX, VAULT, "
                   "priority_of",
          scope=ACCEPT["AGENTS.md 10.12 coordinate-clicks example (mechanism shown)"]),
     True),
]


def main() -> int:
    print("A. validate_scope - must ACCEPT mechanism-complete scopes")
    for name, scope in ACCEPT.items():
        ok, msg = V.validate_scope(scope)
        check(f"accept | {name}", ok, msg or "accepted")

    print("\nB. validate_scope - must REJECT mechanism-free scopes")
    for name, scope in REJECT.items():
        ok, msg = V.validate_scope(scope)
        check(f"reject | {name}", not ok, msg if not ok else "WRONGLY ACCEPTED")

    print("\nC. propose() enforces the same rule (10.4 + 10.12)")
    V.VAULT = Path(tempfile.mkdtemp(prefix="scope_"))
    for name, kwargs, should_pass in PROPOSAL_CASES:
        out = V.propose(**kwargs, date="2026-10-31")
        if should_pass:
            ok = out.startswith("Proposed to inbox")
            detail = out[:60]
        else:
            ok = out.startswith(("ERROR", "REJECTED")) and "10.12" in out
            detail = out.split("\n")[-1][:80]
        check(name, ok, detail)

    failed = [n for n, ok in results if not ok]
    print(f"\nDAY 17-19 RESULT: {len(results) - len(failed)}/{len(results)} passed"
          f"{' - ALL GREEN' if not failed else ' - ' + str(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
