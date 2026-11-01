"""Day 8 acceptance test: real MCP client over stdio against mcp_vault.py.

Run:  python test_mcp_client.py
"""

import asyncio
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))

from mcp import ClientSession, StdioServerParameters  # noqa: E402
from mcp.client.stdio import stdio_client  # noqa: E402

PROJECT = Path(__file__).resolve().parent
EXPECTED_TOOLS = {"vault_read", "vault_propose", "vault_recall",
                  "vault_stale_suggestion"}

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" -> {detail}" if detail else ""))


async def main():
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(PROJECT / "mcp_vault.py")],
        cwd=str(PROJECT),
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            names = {t.name for t in tools.tools}
            check("1. server exposes exactly the 4 vault tools",
                  names == EXPECTED_TOOLS, ",".join(sorted(names)))

            res = await session.call_tool("vault_recall",
                                          {"query": "COMPLETE table"})
            out = res.content[0].text
            lines = [l.strip() for l in out.split("\n") if l.strip()]
            check("2a. vault_recall returns exactly 3 notes (10.2)",
                  len(lines) == 3, f"{len(lines)} lines")
            check("2b. all 3 are the High Priority lessons",
                  all(l.startswith("lessons/") for l in lines)
                  and sum("COMPLETE table" in l for l in lines) == 2
                  and any("Standing Rules" in l for l in lines),
                  " | ".join(l[:40] for l in lines))
            check("2c. summaries are real text, not [REDACTED]",
                  all("[REDACTED" not in l for l in lines)
                  and all(len(l) > 60 for l in lines))

            res = await session.call_tool("vault_read", {"path": "INDEX.md"})
            out = res.content[0].text
            check("3a. vault_read reads INDEX.md",
                  "Vault INDEX" in out, out[:40].replace("\n", " "))
            res = await session.call_tool("vault_read",
                                          {"path": "../AGENTS.md"})
            out = res.content[0].text
            check("3b. vault_read denies path outside the vault (10.3)",
                  "Outside vault" in out, out[:60])

            res = await session.call_tool("vault_propose", {
                "claim": "fake observation used for the Day 8 client test",
                "source": "agent observed it",
                "evidence": "path: D:/does/not/exist/nope.py | excerpt: "
                            "from vault_lib import SECRET_REGEX",
                "scope": ("primary: MCP tool test harness | transferable: any "
                          "CLI test suite, same assertion mechanism | "
                          "unconventional: manufacturing QA - a probe instrument "
                          "checks a part that was never made, via the same "
                          "existence check"),
            })
            out = res.content[0].text
            check("4. vault_propose rejects a hallucinated evidence path (10.9)",
                  out.startswith(("REJECTED", "ERROR")) and "does not exist" in out,
                  out.split("\n")[0][:70])

            res = await session.call_tool("vault_stale_suggestion", {})
            out = res.content[0].text
            check("5. vault_stale_suggestion answers without deleting (10.7)",
                  "auto-delete" in out or "SUGGEST" in out or "None" in out,
                  out.split("\n")[0][:70])

    failed = [r for r in results if not r[1]]
    print(f"\nDAY 8 RESULT: {len(results) - len(failed)}/{len(results)} passed"
          f"{' - ALL GREEN' if not failed else ''}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
