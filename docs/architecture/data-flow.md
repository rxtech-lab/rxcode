---
slug: architecture/data-flow
title: Data Flow
description: How a user message travels through AppState, the selected backend, and the streaming pipeline.
---

# Data Flow

RxCode drives every agent interaction through a single entry point on the
observable app state and a shared streaming pipeline, regardless of which
backend (Claude Code, Codex, or ACP) serves the request.

## Request lifecycle

1. User input enters `AppState.send(in:)`.
2. `AppState` resolves the selected agent provider, model, effort, permission
   mode, working directory, and optional Git worktree.
3. The selected backend — `ClaudeService`, `CodexAppServer`, or `ACPService` —
   emits an `AsyncStream<StreamEvent>`.
4. `AppState+Stream.swift` processes stream events: updates chat state, tracks
   tool calls, handles permission requests, and persists messages.
5. Permission requests route through the UI and, where needed, through
   `PermissionServer` (CLI hooks) or the ACP/Codex protocol response channels.
6. Thread summaries, branch briefings, change tracking, search indexes,
   widgets, and mobile snapshots update from persisted session state.

## Permission handling

Permission approval is risk-aware and queued in the UI. CLI-based agents call
back into a local HTTP server (`PermissionServer`) that hands the request to
the approval UI; protocol-based agents (ACP, Codex) bridge permission requests
through their respective protocol responses. `BashSafety` provides read-only
command validation for agent-exposed shell helpers.

## Persistence and downstream consumers

`PersistenceService` / `ThreadStore` back session and thread state with JSON
under Application Support. Once a session is persisted, several consumers update
off the same source of truth:

- `ThreadSearchService` re-indexes threads for on-device natural-language search.
- Branch briefings and change tracking recompute from session state.
- `RxCodeWidget` reflects active work and usage.
- `MobileSyncService` produces E2E-encrypted snapshots for paired devices.

See [Services](services) for the full service catalog and
[Architecture Overview](overview) for the core patterns these flows rely on.
