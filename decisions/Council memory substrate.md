---
aliases: []
confidence: observed
created: '2026-10-14'
description: Use plain markdown + wikilinks as agent memory; no vector DB, no MCP server, no hosted service
name: Council memory substrate
source: session/council-design
status: active
type: decision
updated: '2026-10-14'
---

## Decision

Plain markdown files in an Obsidian vault are the memory substrate for the agent council.

## Why

- Files are human-readable, greppable, hand-editable, git-versionable.
- No vector DB: for a few thousand notes, ripgrep + the wikilink graph suffices.
- No MCP server: the council's clients are browser tabs driven via CDP, which cannot speak MCP.
- No hosted service (mem0/Zep/Letta): data stays local, and LLM-extraction-per-turn is the transcript-dumping problem with opaque storage.

## What was rejected

- Embeddings / BM25 -- defer until vocabulary-mismatch misses are observed repeatedly.
- openat2 kernel path containment -- Linux only; this is Windows.
- 20-tool MCP server surfaces -- over-engineered for the actual threat model (accidents, not adversaries).

## The five things that actually matter

[[Council write protocol]] -- provenance, supersession, dedupe-on-write, consolidation loop, context budget.

## See also

[[Obsidian CDP access]]
