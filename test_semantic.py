"""test_semantic.py - Day 11-13 acceptance: vector recall over keyword recall.

Run:  python test_semantic.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import semantic_recall as S  # noqa: E402
import vault_lib as V  # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" -> {detail}" if detail else ""))


def brute_force_cosine(query: str) -> list[tuple[str, float]]:
    """True cosine over every note, computed in plain Python. Any divergence
    from the sqlite-vec result would reveal a hidden boost or rerank."""
    q = S.embed([query])[0]
    out = []
    for rec in S._records():
        v = S.embed([S._doc_text(rec)])[0]
        dot = sum(a * b for a, b in zip(q, v))
        out.append((rec["path"], 1.0 - dot))
    return sorted(out, key=lambda t: t[1])


def main() -> int:
    print("embedder:", S.backend())
    print("vector store:", S.VECTORS_DB.name)
    print("-" * 74)

    check("1. backend is reported honestly (10.10), not dressed up as neural",
          ("local-feature-hash" in S.backend() or S.MODEL in S.backend()),
          S.backend())

    ann = S.rank("give me table", 3)
    bf = brute_force_cosine("give me table")
    check("2. sqlite-vec cosine == plain-Python cosine top-3 "
          "(no rerank, no hardcoded boost)",
          [p for p, _ in ann] == [p for p, _ in bf[:3]]
          and all(abs(a - b) < 1e-4 for (_, a), (_, b) in zip(ann, bf[:3])),
          f"ann={[p.split('/')[-1][:26] for p, _ in ann]}")

    table_path = next(p for p, _ in ann)
    dist = dict(ann)
    ranked_all = dict(S.rank("give me table", len(S._records())))
    drift_path = "lessons/Two lists that must agree will drift.md"
    check("3. 'give me table' beats 'Two lists drift' by raw cosine",
          "COMPLETE table" in table_path
          and ranked_all[drift_path] > dist[table_path],
          f"table={dist[table_path]:.4f} < drift={ranked_all[drift_path]:.4f}")

    hits = S.semantic_recall("give me table", 3)
    check("4. drift note is not in the top-3 for that query",
          all("Two lists" not in h for h in hits),
          " || ".join(h.split(" | ")[0][:34] for h in hits))

    hits = S.semantic_recall("COMPLETE table", 3)
    high = {r["path"] for r in (V._index_records() or []) if V._is_high(r)}
    got = {h.split(" | ")[0] for h in hits}
    check("5. Day 8 contract still holds: 3 High Priority lessons",
          len(hits) == 3 and got == high,
          " || ".join(p.split("/")[-1][:30] for p in got))

    sem = S.semantic_recall("indentation errors", 3)
    key = V.recall_from_index("indentation errors", 3)
    check("6. vector recall finds what keyword recall misses "
          "('indentation errors' -> 'IndentationError Fix')",
          "IndentationError" in sem[0] and "IndentationError" not in key[0],
          f"semantic[0]={sem[0].split(' | ')[0].split('/')[-1][:34]} | "
          f"keyword[0]={key[0].split(' | ')[0].split('/')[-1][:34]}")

    d = [x[1] for x in ann]
    check("7. distances are monotone raw cosine (0.0 best), no re-sorting",
          all(d[i] <= d[i + 1] + 1e-9 for i in range(len(d) - 1))
          and all(0.0 <= x <= 2.0 for x in d),
          ", ".join(f"{x:.4f}" for x in d))

    failed = [n for n, ok in results if not ok]
    print(f"\nDAY 11-13 RESULT: {len(results) - len(failed)}/{len(results)} passed"
          f"{' - ALL GREEN' if not failed else ' - ' + str(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
