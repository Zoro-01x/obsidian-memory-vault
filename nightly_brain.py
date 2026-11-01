"""nightly_brain.py - Day 23-25: the second-brain nightly cleanup pass.

Everything here is a SUGGESTION or a deterministic rebuild. Notes are never
edited, merged, archived or deleted by this script - those are RED actions
reserved for Sam (10.7, AGENTS.md). The only write into the vault is INDEX.md,
which 10.6 explicitly makes automated.

Steps:
  1. old facts      - notes untouched/unverified > 90d -> re-verify suggestion
  2. orphan links   - notes no other note references   -> suggested [[links]]
  3. duplicate pairs- lessons about the same topic     -> merge into 1
                      canonical with N evidences (suggestion only)
  4. index rebuild  - delegates to build_index.py (deterministic, no AI)

Run:   python nightly_brain.py                 # full pass, rebuilds INDEX
       python nightly_brain.py --no-rebuild     # report only
       python nightly_brain.py --selftest       # Day 23-25 acceptance checks
Writes: brain_report.md next to this file (never inside the vault).
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_index  # noqa: E402
import vault_lib as V  # noqa: E402

REPORT = Path(__file__).resolve().parent / "brain_report.md"
OLD_FACT_DAYS = 90
DUP_TITLE_JACCARD = 0.40      # title overlap that means "same lesson"
LINK_SUGGEST_CAP = 10

STOP = {"the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is",
        "are", "be", "with", "as", "at", "by", "from", "that", "this", "it",
        "in", "not", "no", "my", "your", "we", "you", "i"}


def approved_notes() -> list[Path]:
    return [p for folder in ("entities", "decisions", "lessons")
            for p in sorted((V.VAULT / folder).glob("*.md"))
            if p.exists()]


def _tokens(text: str) -> set:
    return {w for w in re.findall(r"[a-z0-9']+", text.lower())
            if len(w) > 2 and w not in STOP}


def _body(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="ignore")


def _stem(p: Path) -> str:
    return p.stem.lower()


# ---------------------------------------------------------------- 1. old facts
def old_facts(notes: list[Path]) -> list[str]:
    out, now = [], datetime.now()
    for p in notes:
        age = (now - datetime.fromtimestamp(p.stat().st_mtime)).days
        meta = V._get_meta(_body(p))
        verified = meta.get("verified") or meta.get("updated") or ""
        v_days = None
        m = re.match(r"(\d{4}-\d{2}-\d{2})", verified)
        if m:
            v_days = (now.date() - datetime.fromisoformat(m.group(1)).date()).days
        stale_for = min([x for x in (age, v_days) if x is not None] or [age])
        if stale_for > OLD_FACT_DAYS:
            out.append(f"{p.parent.name}/{p.name} | age {age}d | last verified "
                       f"{v_days if v_days is not None else '?'}d | "
                       f"RE-VERIFY suggestion (10.10) - never auto-edit")
    return out


# ------------------------------------------------------------- 2. orphan links
def orphans(notes: list[Path]) -> list[tuple[str, str]]:
    """(orphan, suggested related note) - suggestion only, files untouched."""
    bodies = {p: _body(p).lower() for p in notes}
    out = []
    for p in notes:
        stem = _stem(p)
        referenced = any(stem in bodies[q].lower()
                         for q in notes if q != p)
        if referenced:
            continue
        toks = _tokens(_body(p)) | _tokens(p.stem)
        best, best_score = None, 0
        for q in notes:
            if q == p:
                continue
            other = _tokens(_body(q)) | _tokens(q.stem)
            score = len(toks & other) / max(1, len(toks | other))
            if score > best_score:
                best, best_score = q, score
        rel = (f"{best.parent.name}/{best.name} (overlap {best_score:.2f})"
               if best else "none")
        out.append((f"{p.parent.name}/{p.name}", rel))
    out.sort(key=lambda t: t[0])
    return out


# ------------------------------------------------------- 3. duplicate lessons
def duplicate_pairs(notes: list[Path]) -> list[dict]:
    """Same-topic lessons that should become ONE canonical note carrying every
    evidence. Reporting only - merging is a RED action for Sam."""
    pairs = []
    for i, p in enumerate(notes):
        for q in notes[i + 1:]:
            tp, tq = _tokens(p.stem), _tokens(q.stem)
            if not tp or not tq:
                continue
            j = len(tp & tq) / len(tp | tq)
            if j >= DUP_TITLE_JACCARD:
                pairs.append({
                    "a": f"{p.parent.name}/{p.name}",
                    "b": f"{q.parent.name}/{q.name}",
                    "jaccard": round(j, 2),
                    "shared": sorted(tp & tq),
                    "evidences": 2,
                })
    pairs.sort(key=lambda d: -d["jaccard"])
    return pairs


# ------------------------------------------------------------------ 4. driver
def run(rebuild: bool = True) -> dict:
    notes = approved_notes()
    result = {
        "when": datetime.now().isoformat(timespec="seconds"),
        "notes": len(notes),
        "old_facts": old_facts(notes),
        "orphans": orphans(notes),
        "duplicates": duplicate_pairs(notes),
        "index": "skipped (--no-rebuild)",
    }
    if rebuild:
        result["index"] = "rebuilt" if build_index.build_index() == 0 else "FAILED"
    write_report(result)
    return result


def write_report(result: dict) -> None:
    lines = [
        "# Nightly brain report",
        f"Generated: {result['when']} (Day 23-25 cleanup pass)",
        "",
        "Everything below is a suggestion for Sam. Nothing was edited, "
        "merged, archived or deleted (10.7 / RED actions).",
        "",
        f"## 1. Old facts to re-verify (>{OLD_FACT_DAYS}d, 10.10)",
    ]
    lines += [f"- {x}" for x in result["old_facts"]] or ["- none"]
    lines += ["", "## 2. Orphan notes (no other note references them)"]
    lines += [f"- {o} -> suggest link to {r}" for o, r in
              result["orphans"][:LINK_SUGGEST_CAP]]
    if len(result["orphans"]) > LINK_SUGGEST_CAP:
        lines.append(f"- ... {len(result['orphans']) - LINK_SUGGEST_CAP} more")
    lines += ["", "## 3. Duplicate lessons - merge suggestion "
              "(1 canonical note, N evidences)"]
    if not result["duplicates"]:
        lines.append("- none")
    for d in result["duplicates"]:
        lines.append(f"- MERGE SUGGESTION ({d['jaccard']}): {d['a']}  +  "
                     f"{d['b']}  ->  1 canonical note carrying "
                     f"{d['evidences']} evidences | shared: "
                     f"{', '.join(d['shared'][:8])}")
    lines += ["", "## 4. Index", f"- {result['index']}", ""]
    REPORT.write_text("\n".join(lines), encoding="utf-8")


def selftest() -> int:
    print("Day 23-25 selftest")
    results = []
    tmp_notes = [
        Path("lessons/Sam always wants the COMPLETE table in one message.md"),
        Path("lessons/Sam prefers COMPLETE table in one message.md"),
        Path("lessons/Standing Rules - Memory Agent Build.md"),
        Path("lessons/Memory-agent build standing rules.md"),
        Path("entities/Unrelated widget entity.md"),
    ]

    def check(name, ok, detail=""):
        results.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}"
              + (f" -> {detail}" if detail else ""))

    # duplicate detection reads only the Paths (no file IO) -> temp names work
    pairs = duplicate_pairs(tmp_notes)
    merged = {tuple(sorted((d["a"].split("/")[-1], d["b"].split("/")[-1])))
              for d in pairs}
    check("1. the two COMPLETE-table lessons are proposed as one canonical",
          ("Sam always wants the COMPLETE table in one message.md",
           "Sam prefers COMPLETE table in one message.md") in merged,
          str([d['jaccard'] for d in pairs]))
    check("2. the two standing-rules notes are proposed as one canonical",
          ("Memory-agent build standing rules.md",
           "Standing Rules - Memory Agent Build.md") in merged)
    check("3. unrelated notes are NOT proposed for merge",
          all("Unrelated widget entity.md" not in a + b
              for a, b in merged))
    check("4. pairs carry an evidence count for the canonical note",
          all(d["evidences"] == 2 for d in pairs))

    # report must be written outside the vault
    res = run(rebuild=False)
    check("5. report writes OUTSIDE the vault (10.3)",
          REPORT.exists() and not str(REPORT).startswith(str(V.VAULT)),
          str(REPORT))
    check("6. report contains no delete/merge command (10.7)",
          not any(w in REPORT.read_text(encoding="utf-8").lower()
                  for w in ("os.remove", "unlink(", "shutil.rmtree", "schtasks /delete")))
    check("7. INDEX untouched in report-only mode",
          res["index"].startswith("skipped"), res["index"])

    ok = all(results)
    print(f"\nDAY 23-25 RESULT: {sum(results)}/{len(results)} passed"
          f"{' - ALL GREEN' if ok else ''}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-rebuild", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()

    res = run(rebuild=not args.no_rebuild)
    print(f"nightly brain: {res['notes']} notes | "
          f"{len(res['old_facts'])} old facts | "
          f"{len(res['orphans'])} orphans | "
          f"{len(res['duplicates'])} duplicate pairs | index {res['index']}")
    for d in res["duplicates"]:
        print(f"  MERGE SUGGESTION: {d['a']} + {d['b']} -> 1 canonical "
              f"({d['evidences']} evidences)")
    print(f"report -> {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
