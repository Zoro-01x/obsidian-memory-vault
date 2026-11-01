---
claim: No changes to AGENTS.md, opencode.json, or opencode.jsonc may be applied without Sam's explicit prior approval; every proposed change must be described in simple terms with full detail about its effects, and applies only after Sam verifies it
source: Sam said it
evidence: Sam: "any chnage in agent.md and opencode.json or jsonc file must not apply without my approval, everytime a change should be proposed in simple terms and in great detail with it's effects to me and should apply only after i verify, update that to memory as a high priority hard coded rule"
date: 2026-11-01
scope: All modifications to AGENTS.md, opencode.json, and opencode.jsonc files
basis: observed
status: proposed - needs Sam approval per 10.4
---

# Proposal: High-Priority Rule — No Config Changes Without Sam's Approval

**Claim:** No changes to `AGENTS.md`, `opencode.json`, or `opencode.jsonc` may be applied without Sam's explicit prior approval; every proposed change must be described in simple terms with full detail about its effects, and applies only after Sam verifies it.

**Source:** Sam said it

**Evidence:** Sam: "any chnage in agent.md and opencode.json or jsonc file must not apply without my approval, everytime a change should be proposed in simple terms and in great detail with it's effects to me and should apply only after i verify, update that to memory as a high priority hard coded rule"

**Date:** 2026-11-01

**Scope:** All modifications to `AGENTS.md`, `opencode.json`, and `opencode.jsonc` files

---

## Rule Details

### 1. No silent or automatic changes
OpenCode (or any agent) must never edit, overwrite, or modify `AGENTS.md`, `opencode.json`, or `opencode.jsonc` without first obtaining Sam's explicit approval.

### 2. Every change must be proposed
Before any change is made, the agent must submit a proposal to Sam containing:
- **What file is changing** (exact path)
- **What the current content is** (relevant section)
- **What the new content will be** (relevant section)
- **Why the change is needed** (simple terms)
- **What effects the change will have** (great detail, including risks and side effects)
- **How to verify the change worked** (verification steps Sam can perform)

### 3. Change applies only after Sam verifies
The agent must wait for Sam to:
- Read the proposal
- Confirm understanding of the effects
- Explicitly approve the change

Only after Sam's explicit approval may the agent make the change.

### 4. High priority hard-coded status
This rule is high priority and takes precedence over other considerations. It overrides any assumption that config changes are routine or safe.

---

Per 10.4: Becomes memory only after Sam approves.