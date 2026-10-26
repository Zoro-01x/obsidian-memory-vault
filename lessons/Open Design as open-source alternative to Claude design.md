---
aliases: ~
basis: user-stated
description: Open source alternative to Claude design tools
name: Open Design as open-source alternative to Claude design
scope: machine
status: active
updated: '2026-10-26'
verified: '2026-10-26'
---

Open Design note created 2026-10-26

# Open Design Tutorial — Open-source alternative to Claude design

## Overview
Open Design refers to open-source tools, patterns, and frameworks that provide AI-assisted design capabilities comparable to or complementary with Claude's design features.

## Part 1: Prompt Engineering Patterns
### Few-shot with critique
Structure your prompt with: 1) Task description, 2) Examples, 3) Critique loop, 4) Revised output.

### Tool-use scaffolding
Prompt patterns that trigger function calling / tool use:
- `DO: <task>` followed by `CHECK: <validation>`
- End with `REFLECT: <what could be improved>`

### Iterative refinement
Three-step cycle:
1. **Generate** — produce initial design output
2. **Evaluate** — score against criteria (1-10)
3. **Improve** — revise based on evaluation feedback

## Part 2: Open-Source Model Alternatives
### Nemotron (NVIDIA)
- Model: `nvidia/nvidia/nemotron-3.5-lightning-30b-a3b`
- Runs locally on Sam's machine
- Via OpenCode at `https://integrate.api.nvidia.com/v1`
- Temperature: 1.0 recommended for design tasks

### DeepSeek variants
- `deepseek-ai/deepseek-v4.1-flash` via NVIDIA NIM endpoint
- Community editions of Llama 3.1 / 3.2
- Can be self-hosted for data sovereignty

## Part 3: Comparison — Open Design vs. Claude

| Factor | Open Design | Claude |
|---|---|---|
| **Cost** | Self-hosted or per-token at NVIDIA rates | Proprietary pricing |
| **Transparency** | Full prompt + model weights (if open) | Black-box |
| **Customization** | Can modify prompts, hyperparameters | Fixed by Anthropic |
| **Data sovereignty** | Runs on Sam's machine / own infra | Data leaves machine |
| **Vendor lock-in** | None — migrate between models | High |
| **Auditability** | Full provenance in vault | Not applicable |

## Part 4: Vault Integration

When you ask me to "design" something:

1. **Check vault first** — look for existing Open Design patterns (`lessons/`)
2. **Use Nemotron** — with the captured prompt patterns from this note
3. **Flag Claude-specific needs** — function calling, system prompts vs. open patterns suffice
4. **Provide open alternative first** — then note Claude equivalents if needed

## Part 5: How to Use This
- Reference this note from any design-related task
- Basis: `user-stated` (you stated this is useful)
- Scope: `machine` (applies to Sam's OpenCode environment)
- Status: `active` — will influence future design answers
- Verified: `2026-10-26`

---
*Tutorial content added 2026-10-26 as part of OpenCode memory persistence.*
