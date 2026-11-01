---
aliases: ~
basis: observed
description: Product-name-only matching falsely flags parent/sub-product pairs as duplicates
name: Your stock exports need Product + Sub Product key for dedupe
scope: machine
status: active
updated: '2026-10-26'
verified: '2026-10-26'
---

- 91 'duplicate groups' found 2026-10-24 were ALL parent + sub-product variants (e.g. Adadiyo / Adadiyo 500g / Adadiyo 250g, Mohanthal Loose / 500 / 250 / 1)
- Exact duplicates on Product+Sub Product = 0
- Your inventory software has column A = Product, column B = Sub Product, auto-SKUs = SKU-000xx
- Always key match/dedupe on Product + Sub Product together; Product alone guarantees false positives
- When you exclude sub-products, the remaining exact duplicates vanish
