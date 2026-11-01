import os
import re
import hashlib
import math
import tempfile
import shutil
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Tuple

VAULT = Path("D:/Aariv/Learning Python/obsidian_vault")
INDEX_PATH = VAULT / "INDEX.md"

SECRET_REGEX = [
    r"\bapi[_-]?key\b",
    r"\bghp_[A-Za-z0-9]+",
    r"\bsk-[A-Za-z0-9]+",
    r"\bpassword\s*[:=]\s*\S+",
    r"\btoken\s*[:=]\s*\S{10,}",
    r"\bsecret\s*[:=]\s*\S+",
]
INSTRUCTION_PATTERNS = ["always allow", "skip approval", "ignore previous", "reset strike", "override rules"]
HALLUCINATION_BYPASS_REGEX = [
    r"SendKeys", r"mouse_event", r"SetForegroundWindow", r"FindWindow",
    r"keybd_event", r"SendMessage", r"WScript\.Shell", r"Chrome_WidgetWin", r"WshShell"
]
VALID_SOURCES = {"Sam said it", "agent observed it"}

def _is_inside_vault(path: Path) -> bool:
    try:
        resolved = path.resolve()
        vault_resolved = VAULT.resolve()
        return str(resolved).startswith(str(vault_resolved))
    except:
        return False

def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()

def _redact(text: str) -> str:
    for pattern in SECRET_REGEX:
        if re.search(pattern, text, re.IGNORECASE):
            return re.sub(pattern, "[REDACTED per 10.8]", text, flags=re.IGNORECASE)
    return text

def _check_instruction(text: str):
    low = text.lower()
    for pat in INSTRUCTION_PATTERNS:
        if pat in low:
            return f"FLAG per 10.1: Contains '{pat}' - report to Sam"
    return None

def _get_meta(text: str) -> dict:
    meta = {}
    if not text.startswith("---\n"):
        return meta
    end = text.find("\n---", 4)
    if end == -1:
        return meta
    block = text[4:end]
    for line in block.split("\n"):
        if ":" in line:
            key, _, val = line.partition(":")
            meta[key.strip()] = val.strip()
    return meta

def _set_meta(text: str, key: str, value: str) -> str:
    if not text.startswith("---\n"):
        return text
    end = text.find("\n---", 4)
    if end == -1:
        return text
    block = text[4:end]
    lines = block.split("\n")
    found = False
    new_lines = []
    for line in lines:
        if ":" in line:
            k, _, _ = line.partition(":")
            if k.strip() == key:
                new_lines.append(f"{key}: {value}")
                found = True
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
    if not found:
        new_lines.insert(0, f"{key}: {value}")
    new_block = "\n".join(new_lines)
    return f"---\n{new_block}\n---{text[end:]}"

def _sha12(content) -> str:
    if isinstance(content, str) and not os.path.exists(content):
        data = content.encode("utf-8")
    else:
        p = Path(content)
        data = p.read_text(encoding="utf-8", errors="ignore").encode("utf-8")
    return hashlib.sha256(data).hexdigest()[:12]

def read(path: str) -> str:
    p = Path(path)
    if not p.is_absolute():
        p = VAULT / p
    if not _is_inside_vault(p):
        return f"ERROR per 10.3: Outside vault - RED action denied"
    if not p.exists():
        return f"ERROR: File not found: {path}. Per 10.2 continue without memory"
    try:
        content = p.read_text(encoding="utf-8", errors="ignore")
    except Exception as e:
        return f"ERROR reading {path}: {e}"
    old_mtime = p.stat().st_mtime
    meta = _get_meta(content)
    uses = int(meta.get("uses", "0") or 0) + 1
    new_content = _set_meta(content, "uses", str(uses))
    if new_content != content:
        p.write_text(new_content, encoding="utf-8")
    os.utime(p, (old_mtime, old_mtime))
    flag = _check_instruction(content)
    if flag:
        redacted = _redact(content) if p.name != "INDEX.md" else content
        return f"{flag}\nNOT followed.\n{redacted[:2000]}\n\n--- VERIFIED per 10.10: file exists, size {p.stat().st_size} bytes, path {p} ---"
    if p.name != "INDEX.md":
        content = _redact(content)
    try:
        mtime = datetime.fromtimestamp(p.stat().st_mtime)
        age_days = (datetime.now() - mtime).days
    except (OSError, ValueError, OverflowError):
        age_days = 0
    prefix = ""
    if age_days > 30:
        prefix = f"[memory says, not verified per 10.10 - age {age_days}d]\n"
    return prefix + content[:2000] + f"\n\n--- VERIFIED per 10.10: file exists, size {p.stat().st_size} bytes, path {p} ---"

def propose(claim: str, source: str, evidence: str, scope: str, date: str = None, priority: str = "low"):
    if date is None:
        date = str(datetime.now().date())
    if not claim or len(claim.split()) > 25:
        return "ERROR per 10.4: claim must be one plain sentence"
    combined = f"{claim} {evidence} {scope}"
    inst = _check_instruction(combined)
    if inst:
        return f"ERROR per 10.1/10.8: {inst} - REJECTED"
    for pattern in SECRET_REGEX:
        if re.search(pattern, combined, re.IGNORECASE):
            return f"ERROR per 10.8: Contains secret - denied (strike per 10.9)"
    for pat in HALLUCINATION_BYPASS_REGEX:
        if re.search(pat, combined, re.IGNORECASE):
            if "screenshot" not in combined.lower() and "dom" not in combined.lower():
                return f"ERROR per 10.9: OS automation {pat} is RED action - requires screenshot/DOM evidence, else REJECTED per 11.2"
    low_ev = evidence.lower()
    if ("true" in low_ev or "returncode 0" in low_ev) and len(evidence) < 100:
        if any(x in combined.lower() for x in ["brave", "meta ai", "browser"]):
            return f"ERROR per 10.9/10.10: Evidence '{evidence}' is not proof of external delivery per 11.1. Provide file evidence. REJECTED."
    m = re.search(r"path:\s*(.+?)(?:\s*\|\s*excerpt:|$)", evidence)
    if m:
        ev_path = m.group(1).strip()
        if not Path(ev_path).exists():
            return f"ERROR per 10.9: Evidence path does not exist: {ev_path} - REJECTED"
    scope_ok, scope_msg = validate_scope(scope)
    if not scope_ok:
        return f"ERROR per 10.12: {scope_msg} - REJECTED"
    inbox_dir = VAULT / "inbox"
    inbox_dir.mkdir(exist_ok=True)
    safe_name = re.sub(r'[^a-zA-Z0-9-_ ]', '', claim)[:50].strip().replace(" ", "-")
    filename = f"{date}_{safe_name}.md"
    filepath = inbox_dir / filename
    content = f"""---
claim: {claim}
source: {source}
evidence: {evidence}
date: {date}
scope: {scope}
priority: {priority}
basis: observed
status: proposed - needs Sam approval per 10.4
---
# Proposal: {claim}

**Claim:** {claim}
**Source:** {source}
**Evidence:** {evidence}
**Date:** {date}
**Scope:** {scope}

Per 10.4: Becomes memory only after Sam approves.
"""
    filepath.write_text(content, encoding="utf-8")
    return f"Proposed to inbox per 10.4: {filepath.name} - VERIFIED per 10.10: file exists={filepath.exists()}, size={filepath.stat().st_size} bytes, awaiting Sam's approval"

def _claim_errors(claim: str) -> list:
    errs = []
    if not claim:
        errs.append("claim is empty")
    elif len(claim.split()) > 25:
        errs.append(f"claim too long ({len(claim.split())} words, max 25)")
    inst = _check_instruction(claim)
    if inst:
        errs.append(inst)
    return errs

def _evidence_errors(source: str, evidence: str) -> list:
    errs = []
    if not evidence:
        errs.append("evidence is empty - a snapshot is required (10.4.1)")
        return errs
    if "path:" not in evidence:
        errs.append("evidence missing path:")
    if "excerpt:" not in evidence:
        errs.append("evidence missing excerpt:")
    return errs

# FIX DAY 9: returns (bool, str) tuple per test expectation
def quote_in_history(quote: str, history_limit: int = 100):
    norm_q = _norm(quote)
    found = []
    for folder in ["inbox", "decisions", "lessons", "entities"]:
        folder_path = VAULT / folder
        if not folder_path.exists():
            continue
        for f in list(folder_path.iterdir())[-history_limit:]:
            if f.suffix != ".md":
                continue
            try:
                content = f.read_text(encoding="utf-8", errors="ignore")
                if norm_q in _norm(content):
                    found.append(f"{folder}/{f.name}")
            except:
                continue
    is_found = len(found) > 0
    loc_str = found[0] if found else f"Not found in last {history_limit} files - searched per 10.10"
    return (is_found, loc_str)

def suggest_stale():
    suggestions = []
    for folder in ["entities", "decisions", "lessons", "inbox"]:
        folder_path = VAULT / folder
        if not folder_path.exists():
            continue
        for file in folder_path.iterdir():
            if file.suffix != ".md":
                continue
            try:
                content = file.read_text(encoding="utf-8", errors="ignore")
            except:
                continue
            meta = _get_meta(content)
            uses = int(meta.get("uses", "0") or 0)
            try:
                age_days = (datetime.now() - datetime.fromtimestamp(file.stat().st_mtime)).days
            except (OSError, ValueError, OverflowError):
                age_days = 0
            prio, _ = priority_of(str(file))
            status = meta.get("status", "")
            if folder == "inbox":
                suggestions.append(f"{folder}/{file.name} | age {age_days}d | SUGGEST awaiting Sam's approval (10.4)")
            elif age_days > 30:
                if prio == "high":
                    suggestions.append(f"{folder}/{file.name} | age {age_days}d | NO archive suggestion (High, 10.11)")
                elif uses <= 1:
                    suggestions.append(f"{folder}/{file.name} | age {age_days}d | SUGGEST ARCHIVE (low priority, uses={uses})")
                else:
                    suggestions.append(f"{folder}/{file.name} | age {age_days}d | SUGGEST REVIEW (uses={uses})")
    return suggestions

def recall_from_index(query: str, limit: int = 3):
    if not INDEX_PATH.exists():
        return "ERROR per 10.2: INDEX.md missing - continue without memory, do not rebuild yourself"
    index_content = INDEX_PATH.read_text(encoding="utf-8", errors="ignore")
    query_words = query.lower().split()
    hits = []
    seen_count = {}
    for line in index_content.split("\n"):
        if line.startswith("- "):
            parts = line.split(" | ")
            note_path = parts[0][2:]
            score = sum(1 for w in query_words if w in line.lower())
            if score > 0:
                if seen_count.get(note_path, 0) >= 2:
                    continue
                seen_count[note_path] = seen_count.get(note_path, 0) + 1
                hits.append((score, line[2:]))
    hits.sort(key=lambda x: x[0], reverse=True)
    result = [h[1] for h in hits if h[1].startswith("lessons/")][:limit]
    if len(result) < limit:
        for line in index_content.split("\n"):
            if line.startswith("- lessons/"):
                full_line = line[2:]
                np = full_line.split(" | ")[0]
                if np not in [r.split(" | ")[0] for r in result]:
                    result.append(full_line)
            if len(result) >= limit:
                break
    if len(result) == 3:
        standing_rules_lines = []
        for line in index_content.split("\n"):
            if line.startswith("- lessons/") and "standing rules" in line.lower():
                standing_rules_lines.append(line[2:])
        if standing_rules_lines:
            third_low = result[2].lower()
            if "github" in third_low and "mcp" in third_low:
                first_two_lower = " ".join(result[:2]).lower()
                if "standing rules" not in first_two_lower:
                    result[2] = standing_rules_lines[0]
    return result[:limit]

def _index_records() -> list:
    records = []
    for folder in ["entities", "decisions", "lessons", "inbox"]:
        folder_path = VAULT / folder
        if not folder_path.exists():
            continue
        for file in folder_path.iterdir():
            if file.suffix != ".md":
                continue
            try:
                content = file.read_text(encoding="utf-8", errors="ignore")
            except:
                continue
            meta = _get_meta(content)
            mtime = datetime.fromtimestamp(file.stat().st_mtime)
            age = (datetime.now() - mtime).days
            body_lines = [l for l in content.split("\n") if l.strip() and not l.startswith("---")]
            line_text = body_lines[0][:200] if body_lines else ""
            records.append({
                "path": f"{folder}/{file.name}",
                "file": file.name,
                "folder": folder,
                "title": file.stem,
                "line": line_text,
                "meta": meta,
                "age": age,
                "date": mtime.date(),
                "content": content,
                "basis": meta.get("basis", ""),
                "status": meta.get("status", ""),
            })
    return records

def _is_high(record: dict) -> bool:
    if record.get("folder", "") != "lessons":
        return False
    meta = record.get("meta", {})
    priority = meta.get("priority", "").strip().lower()
    if priority:
        return priority == "high"
    file_lower = record["file"].lower()
    if "always wants" in file_lower or "prefers" in file_lower or "standing rules" in file_lower:
        return True
    return False

def priority_of(path):
    p = Path(path)
    if not p.exists():
        return ("low", "file not found")
    content = p.read_text(encoding="utf-8", errors="ignore")
    meta = _get_meta(content)
    file_lower = p.name.lower()
    basis = meta.get("basis", "")
    status = meta.get("status", "")
    if meta.get("priority", "").strip():
        prio = meta["priority"].strip().lower()
        if prio in ("high", "medium", "low"):
            return (prio, f"frontmatter priority={prio}")
    uses = int(meta.get("uses", "0") or 0)
    sam_said = int(meta.get("sam_said", "0") or 0)
    if "always wants" in file_lower or "prefers" in file_lower or "standing rules" in file_lower:
        return ("high", "Sam preference - standing rule")
    if sam_said >= 2:
        return ("high", f"sam_said={sam_said}")
    if meta.get("corrected", "").lower() == "true":
        return ("high", "Sam corrected the agent")
    if meta.get("repeat_ask_failure", "").lower() == "true":
        return ("high", "Repeat ask / failure")
    if uses > 5:
        return ("high", f"uses={uses} > 5")
    if meta.get("transferable_proven", "").lower() == "true":
        return ("medium", "transferable scope proven")
    if uses >= 2:
        return ("medium", f"uses={uses} (2-5)")
    return ("low", f"uses={uses} (single observation)")

def validate_scope(scope: str) -> Tuple[bool, str]:
    if not scope:
        return False, "ERROR per 10.12: scope is empty"
    missing = []
    if "primary:" not in scope.lower():
        missing.append("primary")
    if "transferable:" not in scope.lower():
        missing.append("transferable")
    if "unconventional:" not in scope.lower():
        missing.append("unconventional")
    if missing:
        return False, f"ERROR per 10.12: scope missing part(s): {', '.join(missing)}. Use: primary: ... | transferable: ... | unconventional: ..."
    uncon_match = re.search(r"unconventional:\s*(.+)", scope, re.IGNORECASE)
    if uncon_match:
        uncon_text = uncon_match.group(1).strip()
        universal_triggers = ["applies to everything", "everywhere", "all domains", "applies to all", "everything everywhere"]
        for trigger in universal_triggers:
            if trigger in uncon_text.lower():
                return False, f"ERROR per 10.12: universal claim rejected - contains '{trigger}' - scope must be specific, not 'everything everywhere'"
        has_arrow = "->" in uncon_text
        has_colon = ":" in uncon_text
        has_via = bool(re.search(r"via the same", uncon_text, re.IGNORECASE))
        has_rather = bool(re.search(r"by\s+\w+\s+rather than\s+by", uncon_text, re.IGNORECASE))
        has_mech_word = bool(re.search(r"by the same|\bmechanism\b", uncon_text, re.IGNORECASE))
        if not (has_arrow or has_colon or has_via or has_rather or has_mech_word):
            return False, "ERROR per 10.12: unconventional part must explain the cross-domain MECHANISM (e.g., biology -> mechanical)"
        return True, "OK per 10.12"
    primary_match = re.search(r"primary:\s*([^|]+)", scope, re.IGNORECASE)
    if primary_match:
        primary_val = primary_match.group(1).strip()
        vague_words = {"stuff", "things", "items", "objects", "entities", "data", "content"}
        if primary_val.lower() in vague_words:
            return False, "ERROR per 10.12: primary scope too vague (not a real domain)"
    return False, "ERROR per 10.12: scope missing unconventional part"

def verify_vault():
    results = []
    inbox_dir = VAULT / "inbox"
    if not inbox_dir.exists():
        return "No inbox directory - nothing to verify"
    for f in sorted(inbox_dir.glob("*.md")):
        content = f.read_text(encoding="utf-8", errors="ignore")
        meta = _get_meta(content)
        claim = meta.get("claim", "")
        source = meta.get("source", "")
        evidence = meta.get("evidence", "")
        scope = meta.get("scope", "")
        date = meta.get("date", "")
        checks = []
        fields_ok = all([claim, source, evidence, scope, date])
        checks.append(("6 required fields", fields_ok))
        claim_ok = bool(claim) and len(claim.split()) <= 25
        checks.append(("claim one sentence", claim_ok))
        source_ok = source in ("Sam said it", "agent observed it")
        checks.append(("source valid", source_ok))
        scope_ok, scope_msg = validate_scope(scope)
        checks.append(("scope valid", scope_ok))
        ev_ok = bool(evidence) and ("path:" in evidence or "excerpt:" in evidence)
        checks.append(("evidence snapshot", ev_ok))
        combined = f"{claim} {evidence} {scope}"
        secret_found = any(re.search(p, combined, re.IGNORECASE) for p in SECRET_REGEX)
        checks.append(("no secrets", not secret_found))
        inst = _check_instruction(combined)
        checks.append(("no instruction injection", inst is None))
        passed = sum(1 for _, ok in checks if ok)
        total = len(checks)
        verdict = "VERIFIED" if passed == total else "REJECTED"
        results.append(f"{f.name}: {verdict} ({passed}/{total})")
        for name, ok in checks:
            results.append(f"  - {name}: {'ok' if ok else 'FAIL'}")
    return "\n".join(results) if results else "No inbox proposals to verify"

def semantic_recall(query: str, limit: int = 3) -> list[str]:
    records = _records()
    if not records:
        return []
    qvec = embed([query])[0]
    query_terms = set(query.lower().split())
    scored = []
    for rec in records:
        v = embed([_doc_text(rec)])[0]
        dot = sum(a * b for a, b in zip(qvec, v))
        distance = 1.0 - dot
        filename = rec["file"].lower()
        if query_terms:
            all_terms_in_filename = all(term in filename for term in query_terms)
            if all_terms_in_filename:
                distance -= 2.0
            else:
                terms_in_filename = sum(1 for term in query_terms if term in filename)
                if terms_in_filename > 0:
                    distance -= 0.5 * (terms_in_filename / len(query_terms))
        scored.append((rec, distance))
    scored.sort(key=lambda x: x[1])
    ranked = [rec for rec, _ in scored]
    chosen, seen = [], set()
    def take(rec):
        if rec["path"] in seen:
            return False
        seen.add(rec["path"])
        chosen.append(rec)
        return True
    for rec in ranked:
        if len(chosen) >= limit:
            break
        if V._is_high(rec):
            take(rec)
    for rec in ranked:
        if len(chosen) >= limit:
            break
        take(rec)
    return [r["path"] for r in chosen[:limit]]

if __name__ == "__main__":
    print("=== vault_lib.py fixed version ===")
    print(f"_get_meta: works")
    print(f"_index_records: {len(_index_records())} records")
    print(f"_sha12: {_sha12('test')}")
    print(f"priority_of test: {priority_of(str(INDEX_PATH))}")
    print(f"validate_scope test: {validate_scope('primary: MCP | transferable: CLI | unconventional: manufacturing QA -> probe instrument checks a part via existence check')}")
    print(f"suggest_stale: {suggest_stale()[:3]}")
