---
aliases: ['vscode font', 'Arial', 'Georgia', 'editor.fontFamily', 'letterSpacing']
basis: user-stated
description: Sam's VS Code font = Arial on all 4 surfaces (editor/terminal/debug console/notebook output) in %APPDATA%\Code\User\settings.json, plus letterSpacing -0.5 on editor+terminal; switched from Georgia same day (too airy).
name: Sam uses Georgia as his VS Code font (all surfaces) (2026-10-22-112054)
scope: 'D:\Sam (personal machine, VS Code config)'
status: active
updated: '2026-10-22'
---

## Claim

As of 2026-10-22 Sam's VS Code font is **Arial** on all surfaces: `editor.fontFamily` ("'Arial', sans-serif"), `terminal.integrated.fontFamily`, `debug.console.fontFamily`, `notebook.output.fontFamily` (the latter three "'Arial', monospace") in `%APPDATA%\Code\User\settings.json`. He first picked Georgia the same day, then switched to Arial because Georgia had "too much space between characters".

Also set: `editor.letterSpacing: -0.5` and `terminal.integrated.letterSpacing: -0.5` (added to tighten Georgia, kept after the Arial switch — reset to 0 if it looks cramped). Verified against installed build 2d0b7506a3: editor.letterSpacing clamps to -5..20; the debug console and notebook output have NO letterSpacing setting (only fontFamily/fontSize), so those two cannot be letter-spaced.

Caveats: Arial is proportional, so terminal column-aligned output is slightly misaligned (Consolas is the fix if it bugs him). Revert = delete these 6 font/spacing lines.

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
