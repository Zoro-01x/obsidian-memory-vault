---
aliases: ['powershell encoding', 'utf8 bom', 'console.in']
basis: observed
description: Quoting, BOM and stdin-encoding traps that silently corrupt saved text
name: PowerShell text passing traps
scope: toolchain
status: active
updated: '2026-10-15'
verified: '2026-10-14'
---

## Traps

- **BOM**: PowerShell 5.1 `Set-Content -Encoding UTF8` writes a UTF-8 BOM. Obsidian then silently ignores `obsidian.json` and the vault does not open. Write with `UTF8Encoding($false)`.
- **Quotes**: `powershell.exe -File x.ps1 -Expression '<JS with "quotes">'` mangles the inner double quotes. Pass bodies over stdin as JSON instead -- never as command-line arguments.
- **OEM codepage**: `[Console]::In` decodes redirected stdin with the console OEM codepage, not UTF-8, so non-ASCII text (em dashes, curly quotes) becomes mojibake on disk. Read raw bytes from stdin and decode with `UTF8Encoding` yourself.

**Rule:** anything longer than a word -- a note body, a script, JS -- travels as UTF-8 on stdin.
