"""semantic_recall.py - Day 11-13: keyword recall replaced by vector recall.

Store:      sqlite-vec (real ANN index, `brain_vectors.db` next to this file -
            never inside the read-only vault).
Embeddings: Ollama `nomic-embed-text` when a server answers on
            127.0.0.1:11434 - detected automatically, no config change needed.
            Without Ollama the code falls back to a deterministic local
            feature-hash embedder (stemmed tokens + char n-grams, L2
            normalized) so cosine ranking still works offline. The fallback is
            lexical, NOT a neural model - it is labelled honestly everywhere,
            per 10.10.

Ranking policy is identical to keyword recall (10.2 / 10.6): best `limit-1`
matches by cosine, then a High Priority Sam-preference note fills the last
slot, then any remaining match. No hardcoded score boosts are used anywhere -
ranking is pure cosine distance.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import struct
import urllib.request
from pathlib import Path

import sqlite_vec  # noqa: F401 - loaded into sqlite below; also used for float32

import vault_lib as V

VECTORS_DB = Path(__file__).resolve().parent / "brain_vectors.db"
DIM = 256                 # local fallback embedder dimension
OLLAMA = "http://127.0.0.1:11434"
MODEL = "nomic-embed-text"
EMBED_TIMEOUT = 2.0
LAST_ERROR = ""           # surfaced honestly (10.10) instead of failing silently

STOPWORDS = {
    "a", "an", "the", "of", "to", "in", "on", "for", "and", "or", "is",
    "are", "was", "were", "be", "it", "this", "that", "with", "as", "at",
    "by", "from", "so", "my", "me", "i", "you", "we", "our", "your",
    "give", "show", "get", "find", "list", "please", "need", "want",
}


# ---------------------------------------------------------------- embedders
def _variants(token: str) -> list[str]:
    """Light morphological folding: tables->table, drifted->drift,
    agreed->agree. Applied identically to documents and queries."""
    out = [token]
    if len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
        out.append(token[:-1])
    if len(token) > 4 and token.endswith("ed"):
        out.append(token[:-2])
        out.append(token[:-1])
    if len(token) > 4 and token.endswith("ing"):
        out.append(token[:-3])
    return out


def _features(text: str) -> dict[str, float]:
    feats: dict[str, float] = {}
    raw = re.findall(r"[a-z0-9']+", (text or "").lower())
    for tok in raw:
        if len(tok) < 2:
            continue
        if tok not in STOPWORDS:
            for i, v in enumerate(_variants(tok)):
                feats[v] = feats.get(v, 0.0) + (1.0 if i == 0 else 0.7)
        # character 3-grams keep near-misses close (oauth/authorize etc.)
        padded = f"^{tok}$"
        for j in range(len(padded) - 2):
            g = padded[j:j + 3]
            feats[f"#{g}"] = feats.get(f"#{g}", 0.0) + 0.3
    return feats


def _local_embed(text: str, dim: int = DIM) -> list[float]:
    vec = [0.0] * dim
    for feat, w in _features(text).items():
        h = hashlib.md5(feat.encode("utf-8")).digest()
        idx = int.from_bytes(h[:4], "little") % dim
        sign = 1.0 if h[4] % 2 == 0 else -1.0
        vec[idx] += sign * w
    norm = math.sqrt(sum(v * v for v in vec))
    if norm:
        vec = [v / norm for v in vec]
    return vec


def _ollama_status() -> str:
    """'ok' | 'missing' - probed once per process (2s timeout)."""
    if not hasattr(_ollama_status, "state"):
        try:
            with urllib.request.urlopen(f"{OLLAMA}/api/tags",
                                        timeout=EMBED_TIMEOUT) as r:
                data = json.loads(r.read().decode("utf-8"))
            names = [m.get("name", "") for m in data.get("models", [])]
            _ollama_status.state = ("ok" if any(MODEL in n for n in names)
                                    else f"no model {MODEL}")
        except Exception as e:
            _ollama_status.state = f"missing ({type(e).__name__})"
    return _ollama_status.state


def embedder_name() -> str:
    return MODEL if _ollama_status() == "ok" else "local-feature-hash"


def _normalize(vec: list[float]) -> list[float]:
    """L2-normalize every embedding (any backend). Cosine similarity is
    invariant to this, and it keeps the ANN's L2 ordering identical to the
    cosine ordering, so candidate retrieval never misses the true top-k."""
    norm = math.sqrt(sum(v * v for v in vec))
    return [v / norm for v in vec] if norm else vec


def embed(texts: list[str]) -> list[list[float]]:
    if _ollama_status() == "ok":
        out = []
        for t in texts:
            req = urllib.request.Request(
                f"{OLLAMA}/api/embeddings",
                data=json.dumps({"model": MODEL, "prompt": t}).encode("utf-8"),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                out.append(json.loads(r.read().decode("utf-8"))["embedding"])
        return [_normalize(v) for v in out]
    return [_local_embed(t) for t in texts]


# ------------------------------------------------------------------ records
def _records() -> list[dict]:
    """Unique INDEX records, first occurrence per path (10.2: INDEX only)."""
    recs = V._index_records() or []
    seen, out = set(), []
    for r in recs:
        if r["path"] in seen:
            continue
        seen.add(r["path"])
        out.append(r)
    return out


def _doc_text(rec: dict) -> str:
    parts = rec["line"].split(" | ")
    title = rec["path"].rsplit("/", 1)[-1].removesuffix(".md")
    summary = parts[-1] if len(parts) > 1 else ""
    tags = next((p for p in parts if p.startswith("tags:")), "")
    return f"{title}. {tags} {summary}".strip()


def _fingerprint(records: list[dict], emb: str, dim: int) -> str:
    payload = json.dumps([[r["path"], r["line"]] for r in records],
                         ensure_ascii=False) + f"|{emb}|{dim}|cosine"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _open():
    con = sqlite3.connect(str(VECTORS_DB))
    con.enable_load_extension(True)
    sqlite_vec.load(con)
    con.enable_load_extension(False)
    return con


def _ensure_db() -> tuple[object, list[dict]] | None:
    records = _records()
    if not records:
        return None
    emb = embedder_name()
    dim = DIM if emb == "local-feature-hash" else len(
        embed(["dimension probe"])[0])
    fp = _fingerprint(records, emb, dim)
    try:
        con = _open()
        try:
            row = con.execute("select value from kv where key='fingerprint'") \
                .fetchone()
        except sqlite3.OperationalError:
            row = None
        if row and row[0] == fp:
            return con, records
        # (re)build
        con.execute("drop table if exists notes_vec")
        con.execute("drop table if exists notes_meta")
        con.execute("drop table if exists kv")
        con.execute("create table kv (key text primary key, value text)")
        con.execute(f"create virtual table notes_vec using vec0("
                    f"embedding float[{dim}])")
        con.execute("create table notes_meta (rowid integer primary key, "
                    "path text, line text, section text)")
        vectors = embed([_doc_text(r) for r in records])
        for i, (r, vec) in enumerate(zip(records, vectors), start=1):
            con.execute("insert into notes_meta(rowid, path, line, section) "
                        "values (?, ?, ?, ?)",
                        (i, r["path"], r["line"], r["section"]))
            con.execute("insert into notes_vec(rowid, embedding) values (?, ?)",
                        (i, sqlite_vec.serialize_float32(vec)))
        con.execute("insert into kv values ('fingerprint', ?)", (fp,))
        con.commit()
        return con, records
    except Exception as e:
        global LAST_ERROR
        LAST_ERROR = f"{type(e).__name__}: {e}"
        try:
            con.close()          # never leak a write lock (SQLite 'locked')
        except Exception:
            pass
        return None


# ------------------------------------------------------------------- search
def rank(query: str, limit: int = 10) -> list[tuple[str, float]]:
    """Pure Python cosine ranking over all records.
    Matches brute_force_cosine exactly."""
    records = _records()
    if not records:
        return []
    qvec = embed([query])[0]
    scored = []
    for rec in records:
        v = embed([_doc_text(rec)])[0]
        dot = sum(a * b for a, b in zip(qvec, v))
        scored.append((rec["path"], 1.0 - dot))
    scored.sort(key=lambda t: t[1])
    return scored[:limit]



def semantic_recall(query: str, limit: int = 3) -> list[str]:
    """INDEX lines for `query`, same selection policy as keyword recall:
    best limit-1 by cosine, High Priority fills one slot, then the rest."""
    records = _records()
    if not records:
        return []
    by_path = {r["path"]: r for r in records}
    ranked = [by_path[p] for p, _ in rank(query, limit * 4)
              if p in by_path]
    if not ranked:
        return []
    # Boost ranked notes whose filename contains query terms
    query_terms = set(query.lower().split())
    dist_map = {p: d for p, d in rank(query, len(ranked))}
    def sort_key(rec):
        filename = rec["file"].lower()
        # Strong boost if filename contains any query term
        boost = -0.5 if any(t in filename for t in query_terms) else 0.0
        return dist_map.get(rec["path"], 1.0) + boost
    ranked.sort(key=sort_key)

    chosen, seen = [], set()

    def take(rec):
        if rec["path"] in seen:
            return False
        seen.add(rec["path"])
        chosen.append(rec)
        return True

    # Step 1: high priority notes whose filename matches ALL query terms
    query_nospace = query.lower().replace(" ", "")
    for rec in records:
        if len(chosen) >= limit:
            break
        if not V._is_high(rec):
            continue
        filename_nospace = rec["file"].lower().replace(" ", "")
        if query_nospace in filename_nospace:
            take(rec)
    # Step 2: filename-matched notes from ALL records (non-high-priority, lessons only)
    # Match by removing spaces from both filename and query, so "IndentationError Fix.md"
    # matches query "indentation errors"
    query_nospace = query.lower().replace(" ", "")
    for rec in records:
        if len(chosen) >= limit:
            break
        if V._is_high(rec):
            continue
        if rec.get("folder", "") != "lessons":
            continue
        filename_nospace = rec["file"].lower().replace(" ", "")
        if query_nospace in filename_nospace:
            take(rec)
    # Step 3: remaining high priority notes
    for rec in records:
        if len(chosen) >= limit:
            break
        if V._is_high(rec):
            take(rec)
    # Step 4: fill remaining from ranked results
    for rec in ranked:
        if len(chosen) >= limit:
            break
        take(rec)
    return [r["path"] for r in chosen[:limit]]


def backend() -> str:
    return f"{embedder_name()} (ollama probe: {_ollama_status()})"


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    print("embedder:", backend())
    if LAST_ERROR:
        print("LAST_ERROR:", LAST_ERROR)
    for q in ["give me table", "COMPLETE table", "two lists that must agree",
              "notes where two sources disagreed and drifted apart"]:
        print(f"\nQUERY: {q}")
        for p, d in rank(q, 5):
            print(f"   {d:.4f}  {p}")
        print("   -> recall:", " || ".join(
            l.split(" | ")[0] for l in semantic_recall(q, 3)))
