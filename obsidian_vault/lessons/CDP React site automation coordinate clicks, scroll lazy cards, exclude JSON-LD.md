---
aliases: ~
basis: observed
description: Synthetic `.click()` doesn't fire React; use coordinate events + scrollIntoView + loose text matching
name: CDP React site automation coordinate clicks, scroll lazy cards, exclude JSON-LD
scope: machine
status: active
updated: '2026-10-26'
verified: '2026-10-26'
---

- 2026-10-25: ixigo booking tab — synthetic `.click()` on SL rows did not trigger booking flow
- Fixed: real coordinate-based mouse events via CDP, element.scrollIntoView() first, exclude `<script>` JSON-LD content
- Availability text drifts live; match loosely on partial patterns, not exact strings
- Lazy-rendered cards: scroll into view before acting; bottom-of-page login/OTP walls are the natural handoff boundary
- After clicking 'Book', expect login screen; stop there — OTP/payment are user's domain
