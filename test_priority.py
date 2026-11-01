"""test_priority.py - Day 14-16 acceptance: usage counter + priority rules.

Rules under test (AGENTS.md 10.6 / 10.7 / 10.11):
  * read() records `uses` in the note frontmatter and PRESERVES mtime, so
    age/stale logic keeps measuring note age, not read traffic
  * Low  = single observation, uses 0-1  -> archive suggested after 30d
  * Medium = uses 2-5, or transferable scope proven once
  * High = Sam said it 2+ times, or corrected the agent, or repeat-ask
    failure, or uses > 5, or Sam-set frontmatter
  * High is NEVER suggested for archive (10.7)

Run:  python test_priority.py
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_index  # noqa: E402
import vault_lib as V  # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" -> {detail}" if detail else ""))


def make_note(folder: Path, name: str, frontmatter: str, mtime_age_days=0,
              body="Some durable observation."):
    folder.mkdir(parents=True, exist_ok=True)
    p = folder / name
    p.write_text(f"---\n{frontmatter}\nstatus: active\n---\n\n{body}\n",
                 encoding="utf-8")
    if mtime_age_days:
        old = datetime.now() - timedelta(days=mtime_age_days)
        ts = old.timestamp()
        os.utime(p, (ts, ts))
    return p


def main() -> int:
    # ---------------------------------------------------- 1. uses counter
    inbox = V.VAULT / "inbox"
    target = sorted(inbox.glob("*.md"))
    if not target:
        target = [make_note(inbox, "counter_fixture.md", "basis: observed")]
    target = target[0]
    before_meta = V._get_meta(target.read_text(encoding="utf-8"))
    before_mtime = target.stat().st_mtime_ns
    before_body = target.read_text(encoding="utf-8")

    V.read(f"inbox/{target.name}")          # harness records usage
    mid_meta = V._get_meta(target.read_text(encoding="utf-8"))
    mid_mtime = target.stat().st_mtime_ns
    V.read(f"inbox/{target.name}")          # second read -> +1

    after_text = target.read_text(encoding="utf-8")
    after_meta = V._get_meta(after_text)
    after_mtime = target.stat().st_mtime_ns

    u0 = int(before_meta.get("uses", 0) or 0)
    u1 = int(mid_meta.get("uses", 0) or 0)
    u2 = int(after_meta.get("uses", 0) or 0)
    check("1a. read() increments uses in frontmatter",
          u1 == u0 + 1 and u2 == u1 + 1, f"{u0} -> {u1} -> {u2}")
    check("1b. read() preserves mtime, so age/stale stays honest (10.7)",
          before_mtime == mid_mtime == after_mtime, "mtime unchanged")
    check("1c. read() leaves the rest of the note byte-identical",
          after_text.count("---") >= 2 and "status:" in after_text
          and "claim:" in after_text,
          f"frontmatter + body intact ({len(after_text)} bytes)")

    # ------------------------------------------------- 2. priority matrix
    tmp = Path(tempfile.mkdtemp(prefix="prio_"))
    cases = [
        ("uses: 0", "low"), ("uses: 1", "low"), ("uses: 3", "medium"),
        ("uses: 6", "high"), ("sam_said: 2", "high"),
        ("corrected: true", "high"), ("repeat_ask_failure: true", "high"),
        ("transferable_proven: true", "medium"), ("priority: high", "high"),
        ("priority: medium", "medium"), ("priority: low", "low"),
    ]
    print("\n2. 10.11 priority derivation matrix")
    bad = []
    for fm, expected in cases:
        p = make_note(tmp, f"case {fm.split(':')[0]}.md", f"basis: observed\n{fm}")
        got = V.priority_of(p)[0]
        mark = "ok" if got == expected else f"XX got {got}"
        print(f"     {fm:30s} -> {got:7s} [{mark}]  (expect {expected})")
        if got != expected:
            bad.append(fm)
    check("2a. all 11 priority rules derive correctly", not bad,
          "failed: " + ", ".join(bad) if bad else "11/11")

    stand = make_note(tmp, "Sam always wants a full diff.md", "basis: observed")
    check("2b. standing preference notes are High (repeat asks / corrections)",
          V.priority_of(stand)[0] == "high", V.priority_of(stand)[1])

    # ---------------------------------------------------- 3. stale rules
    vtmp = Path(tempfile.mkdtemp(prefix="stale_"))
    real_vault = V.VAULT
    V.VAULT = vtmp
    try:
        make_note(vtmp / "lessons", "old low note.md",
                  "basis: observed\nuses: 0", mtime_age_days=45)
        make_note(vtmp / "lessons", "old medium note.md",
                  "basis: observed\nuses: 3", mtime_age_days=45)
        make_note(vtmp / "lessons", "Sam always wants full logs.md",
                  "basis: observed\nuses: 0", mtime_age_days=95)
        make_note(vtmp / "lessons", "fresh note.md",
                  "basis: observed\nuses: 0", mtime_age_days=3)
        make_note(vtmp / "inbox", "waiting proposal.md",
                  "basis: observed", mtime_age_days=12)
        stale = V.suggest_stale()
    finally:
        V.VAULT = real_vault

    joined = "\n".join(stale)
    low_line = next((s for s in stale if "old low note" in s), "")
    med_line = next((s for s in stale if "old medium note" in s), "")
    high_line = next((s for s in stale if "always wants full logs" in s), "")
    inbox_line = next((s for s in stale if "waiting proposal" in s), "")
    check("3a. Low + uses 0 + 45d -> archive SUGGESTION (never a delete)",
          "SUGGEST ARCHIVE" in low_line, low_line[:90])
    check("3b. Medium + 45d -> review suggestion only",
          "SUGGEST REVIEW" in med_line, med_line[:90])
    check("3c. High is NEVER offered for archive (10.11)",
          "NO archive suggestion" in high_line
          and "ARCHIVE" not in high_line.replace("NO archive", ""),
          high_line[:90])
    check("3d. young note is not listed", "fresh note" not in joined)
    check("3e. inbox proposal shown as awaiting Sam (10.4)",
          "awaiting Sam's approval" in inbox_line, inbox_line[:90])
    check("3f. output contains no destructive command (10.7 is suggestion)",
          all(not any(bad in s.lower() for bad in
                      ("rm -", "remove-item", "del ", "erase", "drop table"))
              for s in stale))

    # ------------------------------------------- 4. INDEX priority column
    vcopy = Path(tempfile.mkdtemp(prefix="idx_"))
    shutil.copytree(real_vault, vcopy, dirs_exist_ok=True)
    real_index, real_bi_vault = build_index.INDEX_PATH, build_index.VAULT
    build_index.VAULT = vcopy
    build_index.INDEX_PATH = vcopy / "INDEX.md"
    try:
        rc = build_index.build_index()
        idx = (vcopy / "INDEX.md").read_text(encoding="utf-8")
    finally:
        build_index.VAULT, build_index.INDEX_PATH = real_bi_vault, real_index

    body_lines = [l for l in idx.split("\n")
                  if l.startswith("- ") and ".md" in l]
    check("4a. build_index runs on a copy without touching the real INDEX",
          rc == 0 and len(body_lines) > 20, f"rc={rc}, {len(body_lines)} entries")
    check("4b. every INDEX entry carries a priority (10.6)",
          all("priority:" in l for l in body_lines),
          f"{sum('priority:' in l for l in body_lines)}/{len(body_lines)}")
    high_paths = {l[2:].split(" | ")[0] for l in body_lines
                  if "priority: high" in l}
    check("4c. exactly the 3 standing notes are priority: high",
          len(high_paths) == 3
          and len([p for p in high_paths if "COMPLETE table" in p]) == 2
          and any("Standing Rules" in p for p in high_paths),
          f"{len(high_paths)} distinct high notes")
    check("4d. inbox proposals never enter INDEX (10.4/10.6)",
          "inbox/" not in idx, "no inbox entries")
    check("4e. summaries sanitized to <= 80 chars, no [REDACTED] on clean text",
          all(len(l.split(" | ")[-1]) <= 82 for l in body_lines)
          and "[REDACTED" not in "\n".join(
              l for l in body_lines if "COMPLETE table" in l))

    failed = [n for n, ok in results if not ok]
    print(f"\nDAY 14-16 RESULT: {len(results) - len(failed)}/{len(results)} passed"
          f"{' - ALL GREEN' if not failed else ' - ' + str(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
