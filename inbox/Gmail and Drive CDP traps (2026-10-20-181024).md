---
aliases: ['gmail mojibake', 'drive share id decoy', 'cdp clipboard blocked drive']
basis: observed
description: 'Observed 2026-10-19 prepping the Vaibhav email. (1) Gmail deep-link URL fills corrupt non-ASCII: em-dash U+2014 became mojibake (UTF-8 bytes read as C'
name: Gmail and Drive CDP traps (2026-10-20-181024)
scope: toolchain
status: active
updated: '2026-10-20'
---

## Claim

Observed 2026-10-19 prepping the Vaibhav email. (1) Gmail deep-link URL fills corrupt non-ASCII: em-dash U+2014 became mojibake (UTF-8 bytes read as CP1252) or an invisible NBSP - codepoint-scan filled drafts (count U+2014, U+00A0, mojibake triples) before trusting them. (2) execCommand('selectAll') makes no real selection in the Gmail body; Input.insertText then appended, doubling the text. Working replace: focus body, Range.selectNodeContents(b), addRange, strict-check !isCollapsed and long selection, then Input.insertText. (3) The Drive share-dialog iframe URL id= param is a STALE DECOY (preload=false; real file info arrives via postMessage) - it named a different file entirely. True file identity only via app navigation or an unauthenticated uc?export=download probe (PK magic bytes + sha256 vs local). (4) webfetch title of a drive file URL reveals the filename even behind the sign-in wall - usable as identity oracle. (5) Browser.createBrowserContext is not exposed on this Brave CDP browser endpoint (-32601). (6) Screenshots caught a share dialog open for the WRONG file that DOM probes had missed - verify Drive coordinate clicks visually, per step.


## Related
- [[PowerShell text passing traps]]

## Disposition

- [ ] Reviewed by user
- [ ] Promoted to a permanent note
- [ ] Archived (not worth keeping)
