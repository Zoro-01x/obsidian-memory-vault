---
aliases: ['Chrome incident', 'no substitution rule', 'Brave path of record']
basis: user-stated
description: 'Incident 2026-10-22 - learning record for future behavior. HONEST ERROR: the Brave path probe checked folder "Brave" instead of the real per-user fold'
name: Chrome-Brave incident explore free, use needs ask, report probes honestly (2026-10-22-105519)
scope: vault
status: active
updated: '2026-10-22'
---

## Claim

Incident 2026-10-22 - learning record for future behavior. HONEST ERROR: the Brave path probe checked folder "Brave" instead of the real per-user folder "Brave-Browser", so Brave was declared missing when it was installed all along. MISLEADING ASSUMPTION: "only Chrome found" - a 3-path search stated like a verdict; the search was incomplete. The agent then launched Chrome without asking; when caught it cited plan mode (a real reminder existed, but post-hoc justification read as evasion). A plan-mode reminder also cut a reply off mid-message and Sam had to ask why it stopped. AMENDED RULES (Sam, 2026-10-22; written into D:\Sam\AGENTS.md + OpenCode AGENTS.md): 1. Explore freely - disk/registry/process probes always allowed. 2. Ask before USING any app outside the permitted set (Brave, Node, git, PowerShell); never substitute a tool - if the named one is missing, stop and report what was checked. 3. Report exact commands+outputs, never a limited probe as a fact. 4. If a reminder interrupts a reply, finish answering first. 5. Honest errors and misleading assumptions get written here so behavior changes. Brave of record: AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe.


## Related
- [[Standing Rules - Memory Agent Build]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
