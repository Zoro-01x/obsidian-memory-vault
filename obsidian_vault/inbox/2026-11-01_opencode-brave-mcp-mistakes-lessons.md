---
claim: OpenCode wrongly reported Brave was blank at about:blank because the MCP was connected to an isolated Playwright Brave instance instead of Sam's shared Brave window on port 9222
source: agent observed it
evidence: brave_browser_tabs returned "about:blank" while Sam's real Brave had Meta AI open; after launching brave.exe --remote-debugging-port=9222, tabs showed chrome://newtab/ and gemini.google.com/gems/view
date: 2026-11-01
scope: Brave browser automation via MCP
basis: observed
status: proposed - needs Sam approval per 10.4
---

# Proposal: Brave MCP mistakes and lessons learned

**Claim:** OpenCode wrongly reported Brave was blank at about:blank because the MCP was connected to an isolated Playwright Brave instance instead of Sam's shared Brave window on port 9222

**Source:** agent observed it

**Evidence:** brave_browser_tabs returned "about:blank" while Sam's real Brave had Meta AI open; after launching brave.exe --remote-debugging-port=9222, tabs showed chrome://newtab/ and gemini.google.com/gems/view

**Date:** 2026-11-01

**Scope:** Brave browser automation via MCP

---

## Mistakes made

1. **Trusted MCP tab report as ground truth.** `browser_tabs` showed tab 0 at `about:blank` and I told Sam "I see an empty page." Sam's actual Brave window had Meta AI open. The MCP was connected to an isolated `--isolated` Playwright Brave instance (blank about:blank), not Sam's shared desktop Brave.

2. **Claimed success without read-back evidence.** I stated Brave was accessible and blank, then said "you're wrong" when Sam corrected me — violating 10.9 (no read-back = hallucination) and 10.10 (tool return codes are not proof).

3. **Tried wrong Brave path.** Attempted to launch from `C:\Program Files\BraveSoftware\...` which doesn't exist; Brave is at `C:\Users\Home\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe`.

4. **Navigated to meta.ai and got 403.** The fresh Brave instance lacks Sam's authenticated Meta AI session, so meta.ai returned HTTP 403.

5. **Failed to visually switch tabs.** `Control+Tab` via `browser_press_key` changed the MCP-tracked page to Gemini, but Sam reported Meta AI was still visible on screen — confirming the MCP controls a separate Brave process, not Sam's desktop window.

## Lessons learned

1. **The MCP Brave is a separate instance.** Launching `brave.exe --remote-debugging-port=9222` creates a new process. It does NOT join Sam's existing desktop Brave window where Meta AI was active. `--isolated` launches a hidden blank Brave — that was the original "you're wrong" bug.

2. **Shared Brave is Single Source of Truth (per 11.5).** Both human and OpenCode must use the same Brave instance on `http://localhost:9222`, launched with `--remote-debugging-port=9222` (close all Brave first), using `--cdp-endpoint http://localhost:9222`, NEVER `--isolated`.

3. **Snapshot is the only evidence for text-only models.** Per 10.10.2, `brave_browser_snapshot` + `brave_browser_evaluate` + `browser_console_messages` + `browser_tabs` are the proof tools. No screenshots for text-only models. Tool return codes (True/0/OK) are NOT evidence.

4. **User is the eyes.** If Sam says the screen shows something different from the MCP snapshot, trust Sam. The MCP cannot see pixels or confirm what is visually on Sam's monitor.

5. **Post progress files per 11.2.** Every Brave action must post a progress file in `coordination/progress/` with snapshot evidence so Meta AI can read the same state.

Per 10.4: Becomes memory only after Sam approves.