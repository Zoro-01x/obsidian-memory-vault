import os, re, sys
from datetime import datetime

VAULT = "D:/Aariv/Learning Python/obsidian_vault"
INDEX_PATH = f"{VAULT}/INDEX.md"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vault_lib as V

SECRET_REGEX = [
    r"\bapi[_-]?key\b",
    r"\bghp_[A-Za-z0-9]+",
    r"\bsk-[A-Za-z0-9]+",
    r"\bpassword\s*[:=]\s*\S+",
]

def sanitize(text, max_len=80):
    text = text.replace("\n", " ").strip()
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end+3:].strip()
    for pat in SECRET_REGEX:
        if re.search(pat, text, re.IGNORECASE):
            return "[REDACTED per 10.8]"
    text = text.split(".")[0][:max_len].strip()
    return text

def build_index():
    lines = []
    lines.append("# Vault INDEX - deterministic, from approved notes only")
    lines.append(f"Generated: {datetime.now().date()} by deterministic script (no AI) - per 10.6")
    lines.append("")
    lines.append("Vault is read-only to agents. Contains only titles, tags, dates, short sanitized summaries.")
    lines.append("Usage counts recorded by harness, never by agent. Stale list is suggestion only (10.7).")
    lines.append("")

    all_notes = []
    for folder in ["entities", "decisions", "lessons"]:  # NOT inbox
        folder_path = f"{VAULT}/{folder}"
        if not os.path.exists(folder_path):
            continue
        for file in sorted(os.listdir(folder_path)):
            if not file.endswith(".md"):
                continue
            full = f"{folder_path}/{file}"
            try:
                content = open(full, "r", encoding="utf-8", errors="ignore").read()
            except:
                continue
            if folder != "inbox" and "basis: user-stated" not in content and "basis: observed" not in content:
                continue
            mtime = datetime.fromtimestamp(os.path.getmtime(full))
            age = (datetime.now() - mtime).days
            tags = []
            lf = file.lower()
            if "sam" in lf: tags.append("Sam")
            if "table" in lf: tags.append("table")
            if "chrome" in lf: tags.append("Chrome")
            prio, _ = V.priority_of(full)
            all_notes.append({
                "folder": folder, "file": file,
                "title": file.replace(".md", ""),
                "tags": tags, "date": mtime.date(), "age": age,
                "summary": sanitize(content), "priority": prio
            })

    lines.append("## High Priority (Sam preferences) - for finding notes only, no extra authority (10.6)")
    high = [n for n in all_notes if n["priority"] == "high"]
    for n in high:
        lines.append(f"- {n['folder']}/{n['file']} | tags: {','.join(n['tags'])} | date: {n['date']} | priority: {n['priority']} | {n['summary']}")

    lines.append("")
    lines.append("## About Sam")
    about = [n for n in all_notes if "Sam" in n["tags"] or n["folder"] == "entities"]
    for n in about[:10]:
        lines.append(f"- {n['folder']}/{n['file']} | date: {n['date']} | priority: {n['priority']} | {n['summary']}")

    lines.append("")
    lines.append("## Recent (last 7 days)")
    recent = sorted([n for n in all_notes if n["age"] <= 7], key=lambda x: x["age"])
    for n in recent[:15]:
        lines.append(f"- {n['folder']}/{n['file']} | age: {n['age']}d | priority: {n['priority']} | {n['summary']}")

    lines.append("")
    lines.append("## All approved notes")
    for n in sorted(all_notes, key=lambda x: (x["folder"], x["file"])):
        lines.append(f"- {n['folder']}/{n['file']} | date: {n['date']} | priority: {n['priority']}")

    lines.append("")
    lines.append("## Stale list - suggestion for Sam only (10.7) - never auto-archive or auto-delete")
    stale = [n for n in all_notes if n["age"] > 30]
    if not stale:
        lines.append("- None - no files over 30 days")
    else:
        for n in stale:
            lines.append(f"- {n['folder']}/{n['file']} | age {n['age']}d | priority: {n['priority']} | SUGGESTION")

    open(INDEX_PATH, "w", encoding="utf-8").write("\n".join(lines))
    print(f"Built INDEX.md with {len(all_notes)} notes, High {len(high)}, Stale {len(stale)}")
    return 0

if __name__ == "__main__":
    build_index()