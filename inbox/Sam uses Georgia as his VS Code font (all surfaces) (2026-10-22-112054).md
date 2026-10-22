---
aliases: ['vscode font', 'Arial', 'Georgia', 'editor.fontFamily', 'letterSpacing']
basis: user-stated
description: Sam's VS Code font = Arial on all 4 surfaces (editor/terminal/debug console/notebook output) in %APPDATA%\Code\User\settings.json, letterSpacing -4 on editor+terminal — he wants novel-tight spacing, starts tightening escalations at -4. Switched from Georgia same day (too airy).
name: Sam uses Georgia as his VS Code font (all surfaces) (2026-10-22-112054)
scope: 'D:\Sam (personal machine, VS Code config)'
status: active
updated: '2026-10-22'
---

## Claim

As of 2026-10-22 Sam's VS Code font is **Arial** on all surfaces: `editor.fontFamily` ("'Arial', sans-serif"), `terminal.integrated.fontFamily`, `debug.console.fontFamily`, `notebook.output.fontFamily` (the latter three "'Arial', monospace") in `%APPDATA%\Code\User\settings.json`. He first picked Georgia the same day, then switched to Arial because Georgia had "too much space between characters".

Spacing: he wants character spacing tight — "as in a novel" — and it took several rounds of escalating tightening before he stopped (0 → -0.5 → -1.5 → -2.5 → **-4**, final values `editor.letterSpacing: -4` and `terminal.integrated.letterSpacing: -4`). Lesson: start tighter than -0.5 when Sam complains about airy text; he dislikes airy/default spacing strongly. editor.letterSpacing clamps to -5..20 (verified in installed build 2d0b7506a3); below about -4 glyphs can collide. The debug console and notebook output have NO letterSpacing setting (only fontFamily/fontSize), so those two cannot be letter-spaced. If -4 still reads too airy, the structural fix is Arial Narrow (installed) rather than more negative spacing.

Caveats: Arial is proportional, so terminal column-aligned output is slightly misaligned (Consolas is the fix if it bugs him). Revert = delete these 6 font/spacing lines.

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
