---
aliases: ['image input', 'vision support', 'Cannot read clipboard', 'screenshot not visible', 'VL model images', 'image capability guard']
basis: observed
description: opencode images blocked with 'does not support image input' fix is capabilities.input [text,image] on the model; trust described content over a model's denial
name: OpenCode image input needs model capability declaration, and models may deny while seeing
probe_kind: file_hash
probe_target: .config\opencode\opencode.jsonc
scope: 'machine (OpenCode global config, C:/Users/Home)'
status: active
updated: '2026-10-27'
verified: '2026-10-27'
---

Observed 2026-10-26/27 across two sessions after Sam's screenshots were repeatedly refused.

## What happened

OpenCode refused pasted images with `ERROR: Cannot read "clipboard" (this model does not support image input)`. The model on duty (`nemotron-3.5-lightning-30b-a3b`) was text-only, and `opencode.jsonc` declared no model capabilities, so OpenCode's attachment guard dropped image data before it reached the model. The denial was CORRECT for that session.

## The fix (applied 2026-10-27, verified by fresh-session test)

In `C:/Users/Home/.config/opencode/opencode.jsonc`:

1. Default model switched to a vision model: `nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b`.
2. Explicit capability declaration under `providers.nvidia.models["nvidia/nemotron-3.5-super-vl-120b-a12b"].capabilities`: `{ tools: true, input: ["text","image"], output: ["text"] }`. Explicit caps win over catalog metadata, so the guard cannot fire even if models.dev lists the model as text-only.

Verified: fresh session (ses_e8454133affefE2xKDJW4LpTLt, 2026-10-27) received a screenshot and described its contents accurately; a follow-up word-read test also passed. Config reloads on change, but image behavior was unreliable mid-session — a restart/fresh session is the reliable test.

## The second trap: a model can SEE and still say "No"

In that same verified session the assistant opened with "No — I cannot see an actual 'Image 1'" and then accurately described the screenshot's contents (content that existed only in the pixels). The denial was wrong; the description proved the image arrived.

- Symptom: answer denies seeing the image, then describes it.
- Diagnosis: trust content that could only come from the pixels (exact wording, numbers, layout). A hallucination cannot reproduce screenshot-only text.
- Ask a pointed content question ("what word does this say?") instead of "can you see this?" — the yes/no framing invites a habitual denial.

## Rules learned

- "Model doesn't support images" vs "session doesn't forward images" are DIFFERENT causes; check which. OpenCode source: the error string lives in packages/core (session-model-request) as the read/attachment guard.
- Supported image formats: PNG, JPEG, GIF, WebP (content-detected). SVG is text; BMP/AVIF/audio/video never reach the model. `media.image` config controls auto-resize (default 2000x2000, 5 MiB base64).
- Mid-session config reload can destabilize the image path; verify in a NEW session before concluding it is fixed.
- Never flip-flop: state once which layer is failing (model capability vs session forwarding) and verify with one content question.
