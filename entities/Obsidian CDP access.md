---
aliases: ['obsidian', 'obsidian debugging']
confidence: observed
created: '2026-10-14'
description: Obsidian 1.14.4 runs with CDP on port 9223; app.metadataCache exposes the real link graph
name: Obsidian CDP access
source: session/obsidian-setup
status: active
type: entity
updated: '2026-10-14'
---

## Facts

- Installed at `C:\Users\Home\AppData\Local\Programs\Obsidian\Obsidian.exe` (1.14.4, winget-hung so it was installed from the GitHub release with `/S`).
- Launched with `--remote-debugging-port=9223`. Brave owns 9222.
- Vault at `C:\Users\Home\Documents\ObsidianVault`.
- No `--user-data-dir`: it redirects Obsidian's config path and breaks the vault registry.

## The link graph, without scraping DOM

`window.app.metadataCache` is reachable via CDP `Runtime.evaluate`. `resolvedLinks` and `unresolvedLinks` return the true graph:

``json
{"Council Test.md":{"Second Note.md":1},"Second Note.md":{"Council Test.md":1}}
``

This is internal API and may shift between versions -- treat grep for `[[name]]` as the fallback that never breaks.

## Gotcha: vault registry is at %APPDATA%\obsidian\obsidian.json

It lists vaults as `{vaults:{<id>:{ts,path,open}}}`. **Writing it with PowerShell 5.1 `Set-Content -Encoding UTF8` adds a BOM and Obsidian silently ignores the file.** Use `UTF8Encoding(False)`.

## See also

[[Council memory substrate]]

## Correction: key format in resolvedLinks

Verified live, the keys are **folder-prefixed paths including `.md`**, not bare
filenames:

```
decisions/Council memory substrate.md -> decisions/Council write protocol.md,
                                          entities/Obsidian CDP access.md
```

The harness's grep fallback in `Get-VaultGraph` returns bare names
(`Council write protocol`), so normalise before joining the two sources.
