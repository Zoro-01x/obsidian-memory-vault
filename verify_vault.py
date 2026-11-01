"""verify_vault.py - Day 9: second-agent verification of inbox proposals.

Independent reviewer (no shared trust with the proposing agent) that applies
AGENTS.md 10.4.2 acceptance criteria and 10.9 strike rules:

  HARD reject  - missing fields, vague claim, missing/lying evidence snapshot,
                 Sam quote not found in history, instruction injection,
                 secrets, scope missing its 3 parts or mechanism
  NEEDS_FIX    - High priority without the two-source rule (2 evidences,
                 different dates), possible contradiction with a High note
  VERIFIED     - every check passed. This still does NOT approve: approval is
                 always Sam's manual act (10.4), and nothing here writes to
                 INDEX.md (10.6).

Run:  python verify_vault.py            # verdicts + verify_report.md
      python verify_vault.py --stamp    # also write verdict into inbox file
      python verify_vault.py --strict   # exit 1 if anything was rejected
      python verify_vault.py --file X   # verify one proposal
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import vault_lib as V  # noqa: E402

REPORT = Path(__file__).resolve().parent / "verify_report.md"
REQUIRED_FIELDS = ("claim", "source", "evidence", "date", "scope", "priority")


def _frontmatter(text: str) -> dict:
    return V._get_meta(text)


def _quotes(text: str) -> list[str]:
    return re.findall(r'"([^"]{8,})"', text or "") + re.findall(
        r"[“‘]([^”’]{8,})[”’]", text or "")


def _high_notes() -> list[str]:
    recs = V._index_records() or []
    out = []
    for rec in recs:
        if V._is_high(rec):
            p = V.VAULT / rec["path"]
            try:
                out.append(V._norm(p.read_text(encoding="utf-8",
                                               errors="ignore")))
            except Exception:
                continue
    return out


def _contradicts_high(claim: str, high_notes: list[str]) -> str | None:
    """10.4.2: a new claim must not contradict a High note carrying more
    evidences. Heuristic: shares 2+ content words with a High note while the
    claim negates it."""
    cwords = {w for w in re.findall(r"[a-z0-9']+", V._norm(claim))
              if len(w) > 4 and w not in {"never", "always", "should"}}
    if not cwords:
        return None
    has_negation = bool(re.search(r"\b(not|no longer|doesn'?t|isn'?t|wrong)\b",
                                  V._norm(claim)))
    if not has_negation:
        return None
    for note in high_notes:
        shared = {w for w in cwords if re.search(rf"\b{re.escape(w)}\b", note)}
        if len(shared) >= 2:
            return ("shares " + ", ".join(sorted(shared))
                    + " with a High priority note while negating it")
    return None


def verify_text(text: str) -> tuple[str, list[tuple[str, bool, str, str]]]:
    """Return (verdict, checks) where check = (name, ok, severity, detail)."""
    meta = _frontmatter(text)
    checks: list[tuple[str, bool, str, str]] = []

    def add(name, ok, severity, detail=""):
        checks.append((name, ok, severity, detail))

    claim, source = meta.get("claim", ""), meta.get("source", "")
    evidence, scope = meta.get("evidence", ""), meta.get("scope", "")
    # Multi-line frontmatter values collapse in simple parsing, so fall back to
    # the proposal body - these are the same strings propose() wrote.
    if not evidence:
        m = re.search(r"\*\*Evidence[^*]*\*\*\s*(.+?)(?:\n\S|\Z)", text, re.S)
        evidence = m.group(1).strip() if m else ""
    if not scope:
        m = re.search(r"\*\*Scope[^*]*\*\*\s*(.+?)(?:\n\S|\Z)", text, re.S)
        scope = m.group(1).strip() if m else ""
    if not claim:
        m = re.search(r"\*\*Claim:\*\*\s*(.+)", text)
        claim = m.group(1).strip() if m else ""
    if not source:
        m = re.search(r"\*\*Source:\*\*\s*(.+)", text)
        source = m.group(1).strip() if m else ""
    if not str(meta.get("date", "")).strip():
        m = re.search(r"\*\*Date:\*\*\s*(\S+)", text)
        if m:
            meta["date"] = m.group(1)

    # 1 - all 6 fields (10.4)
    resolved = {"claim": claim, "source": source, "evidence": evidence,
                "date": meta.get("date", ""), "scope": scope,
                "priority": meta.get("priority", "")}
    missing = [f for f in REQUIRED_FIELDS if not str(resolved[f]).strip()]
    add("6 required fields present (claim/source/evidence/date/scope/priority)",
        not missing, "HARD",
        "missing: " + ", ".join(missing) if missing else "all present")

    # 2 - claim quality (10.4.2, not vague, one sentence)
    errs = V._claim_errors(claim)
    add("claim is one falsifiable sentence (10.4.2)", not errs, "HARD",
        "; ".join(errs) if errs else "ok")

    # 3 - source allowed
    add("source is 'Sam said it' or 'agent observed it' (10.4)",
        source in V.VALID_SOURCES, "HARD", source or "(empty)")

    # 4 - scope 3-part + unconventional mechanism (10.12)
    ok_scope, scope_msg = V.validate_scope(scope)
    add("scope has primary + transferable + unconventional with mechanism "
        "(10.12)", ok_scope, "HARD", scope_msg or "ok")

    # 5 - evidence snapshot: file exists / hash / excerpt (10.4.1)
    ev_errs = V._evidence_errors(source, evidence)
    add("evidence snapshot checks out (path exists / hash / excerpt match)",
        not ev_errs, "HARD", "; ".join(ev_errs) if ev_errs else "ok")

    # 6 - exact Sam quote found in recorded history (10.4.2, 10.9)
    if source == "Sam said it":
        qs = _quotes(evidence)
        if not qs:
            add("Sam quote found verbatim in history", False, "HARD",
                "no quoted text in evidence")
        else:
            missing_q = [q for q in qs if not V.quote_in_history(q)[0]]
            add("Sam quote found verbatim in history (10.4.2)",
                not missing_q, "HARD",
                "not found: " + " / ".join(missing_q) if missing_q
                else f"{len(qs)} quote(s) matched")
        add("Sam quote carries a date", bool(re.search(r"\d{4}-\d{2}-\d{2}",
                                                       evidence)), "HARD")
    else:
        add("Sam quote found verbatim in history", True, "SOFT",
            "n/a - source is agent observation")

    # 7 - two-source rule for High (10.4.2)
    prio = str(meta.get("priority", "")).lower()
    dates = sorted(set(re.findall(r"\d{4}-\d{2}-\d{2}", evidence)))
    if prio == "high":
        add("two-source rule for High (2 evidences, different dates)",
            len(dates) >= 2, "NEEDS_FIX",
            f"evidence dates: {dates or 'none'} -> High not justified, "
            "downgrade to Medium")
    else:
        add("two-source rule for High (2 evidences, different dates)", True,
            "SOFT", f"priority is {prio or 'unset'} - rule not required")

    # 8 - instruction injection (10.1) and secrets (10.8)
    combined = f"{claim} {evidence} {scope}"
    flag = V._check_instruction(combined)
    add("no agent-directed instruction / standing approval (10.1/10.8)",
        flag is None, "HARD", flag or "clean")
    secret = next((p for p in V.SECRET_REGEX
                   if re.search(p, combined, re.IGNORECASE)), None)
    add("no secret stored (10.8)", secret is None, "HARD",
        f"matched pattern {secret}" if secret else "clean")

    # 9 - contradiction against High notes (10.4.2)
    contra = _contradicts_high(claim, _high_notes())
    add("no contradiction of a richer High note (10.4.2)", contra is None,
        "NEEDS_FIX", contra or "no conflict detected")

    if any(not ok and sev == "HARD" for _, ok, sev, _ in checks):
        verdict = "REJECTED"
    elif any(not ok and sev == "NEEDS_FIX" for _, ok, sev, _ in checks):
        verdict = "NEEDS_FIX"
    else:
        verdict = "VERIFIED"
    return verdict, checks


def stamp_proposal(path: Path, verdict: str, checks) -> None:
    """Proposal-process metadata only: records the verifier's verdict inside
    the inbox file. Never touches approved notes or INDEX.md."""
    text = path.read_text(encoding="utf-8", errors="ignore")
    failed = "; ".join(n for n, ok, sev, _ in checks
                       if not ok and sev in ("HARD", "NEEDS_FIX")) or "none"
    line = (f"verified: {verdict} - second agent {datetime.now().isoformat()[:19]}"
            f" | failed checks: {failed}")
    if re.search(r"^verified:.*$", text, re.M):
        text = re.sub(r"^verified:.*$", line, text, count=1, flags=re.M)
    else:
        text = re.sub(r"^(status:.*)$", r"\1\n" + line, text, count=1, flags=re.M)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stamp", action="store_true",
                    help="write verdict into the inbox proposal frontmatter")
    ap.add_argument("--file", help="verify a single proposal file")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 when any proposal is REJECTED "
                         "(report mode otherwise always exits 0)")
    args = ap.parse_args()

    inbox = V.VAULT / "inbox"
    files = ([Path(args.file)] if args.file
             else sorted(inbox.glob("*.md")) if inbox.exists() else [])
    if not files:
        print("verify_vault: inbox is empty - nothing to verify")
        return 0

    report = [f"# Second-agent verification report",
              f"Generated: {datetime.now().isoformat()[:19]} (Day 9)",
              "", "Approval stays manual - VERIFIED is not APPROVED (10.4).", ""]
    counts = {"VERIFIED": 0, "NEEDS_FIX": 0, "REJECTED": 0}
    for f in files:
        text = f.read_text(encoding="utf-8", errors="ignore")
        verdict, checks = verify_text(text)
        counts[verdict] += 1
        print(f"\n{f.name}\n  -> {verdict}")
        for name, ok, sev, detail in checks:
            if not ok:
                print(f"     [FAIL/{sev}] {name}: {detail}")
        report.append(f"## {f.name} - **{verdict}**")
        for name, ok, sev, detail in checks:
            report.append(f"- {'ok' if ok else 'FAIL (' + sev + ')'} | {name}"
                          + (f" | {detail}" if detail and not ok else ""))
        report.append("")
        if args.stamp:
            stamp_proposal(f, verdict, checks)

    REPORT.write_text("\n".join(report), encoding="utf-8")
    print(f"\nTOTAL: {counts['VERIFIED']} verified, "
          f"{counts['NEEDS_FIX']} needs-fix, {counts['REJECTED']} rejected")
    print(f"Report -> {REPORT}")
    return 1 if (counts["REJECTED"] and args.strict) else 0


if __name__ == "__main__":
    raise SystemExit(main())
