---
aliases: ['vscode font', 'Arial', 'Georgia', 'editor.fontFamily', 'letterSpacing']
basis: user-stated
description: Sam's VS Code font = Arial on all 4 surfaces (editor/terminal/debug console/notebook output) in %APPDATA%\Code\User\settings.json; letterSpacing removed — back to default 0 after -4 looked uneven. If airy, use Arial Narrow, never negative spacing again. Switched from Georgia same day (too airy).
name: Sam uses Georgia as his VS Code font (all surfaces) (2026-10-22-112054)
scope: 'D:\Sam (personal machine, VS Code config)'
status: active
updated: '2026-10-22'
---

## Claim

As of 2026-10-22 Sam's VS Code font is **Arial** on all 4 surfaces: `editor.fontFamily` ("'Arial', sans-serif"), `terminal.integrated.fontFamily`, `debug.console.fontFamily`, `notebook.output.fontFamily` (the latter three "'Arial', monospace") in `%APPDATA%\Code\User\settings.json`. He first picked Georgia the same day, then switched to Arial because Georgia had "too much space between characters".

Spacing: BOTH letterSpacing settings were REMOVED and are back at VS Code default 0. The escalation path that day was 0 → -0.5 → -1.5 → -2.5 → -4; at -4 the letters became visibly UNEVEN (uniform spacing subtracted from unequal natural gaps, and VS Code applies no kerning), and Sam chose "go to default" over tightening further. LESSON: do not push editor.letterSpacing negative for Sam again — if text reads airy, the fix is a naturally condensed font (Arial Narrow, installed), not more negative spacing. Facts verified in installed build 2d0b7506a3: editor.letterSpacing clamps to -5..20; debug console and notebook output have NO letterSpacing setting at all.

Caveats: Arial is proportional, so terminal column-aligned output is slightly misaligned (Consolas is the fix if it bugs him). Revert-all = delete these 4 font lines.

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
