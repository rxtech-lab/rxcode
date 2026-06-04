---
slug: architecture/overview
title: Architecture Overview
description: High-level design of RxCode, a native macOS client for AI coding agents.
---

# Architecture Overview

RxCode is a native macOS desktop client for AI coding agents, written in Swift
and SwiftUI. It provides a project-centric UI for Claude Code, Codex, and Agent
Client Protocol (ACP) clients, with streaming chat, permission approval flows,
run profiles, Git worktree support, natural-language thread search, mobile
sync, and briefing / change tracking.

The repository also hosts companion targets — widgets, mobile apps (iOS and
Android), a Go relay server for mobile sync, and the public website.

## Targets and components

| Component | Path | Purpose |
| --- | --- | --- |
| macOS app | `RxCode/` | Main desktop client: app entry point, SwiftUI views, services, integrations. |
| Shared core | `Packages/Sources/RxCodeCore/` | Models, theme, utilities, run-profile models, Git helpers, CLI parsing, backend contracts. |
| Chat kit | `Packages/Sources/RxCodeChatKit/` | Reusable chat UI: message rendering, input bar, slash commands, diffs, plans. |
| Sync | `Packages/Sources/RxCodeSync/` | End-to-end encrypted sync protocol, pairing, APNs/FCM payloads, transport types. |
| Widget | `RxCodeWidget/` | Widget and Live Activity support for active work and usage. |
| Mobile | `RxCodeMobile/`, `RxCodeAndroid/` | iOS and Android companion clients. |
| Relay | `relay-server/` | Stateless Go WebSocket relay + APNs/FCM forwarder for desktop ↔ mobile sync. |
| Website | `website/` | Public Next.js website and assets. |

## Platform and tooling

- macOS app deployment target: macOS 26.0+
- Swift tools version: 6.2
- Main app bundle ID: `com.rxlab.RxCode`
- App-level dependencies: SwiftTerm, Sparkle
- Package dependencies: ViewInspector
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
  `SWIFT_APPROACHABLE_CONCURRENCY = YES` are enabled for app/mobile targets.
- App Sandbox is disabled for the main macOS app because RxCode integrates with
  local developer tools and projects.

## Core design patterns

- **Observable app state.** `RxCode/App/AppState.swift` is a
  `@MainActor @Observable` container; behavior is split across `AppState+*.swift`
  extensions by domain.
- **SwiftUI-only UI.** No Storyboards or XIBs.
- **Actor-based services.** Services owning mutable shared state are actors or
  otherwise isolate concurrency through existing patterns.
- **Backend abstraction.** Claude Code, Codex, and ACP flows share backend
  contracts from `RxCodeCore/Backend`, avoiding agent-specific branching where
  the shared protocol suffices.
- **Package boundaries.** `RxCodeCore` stays broadly reusable and free of
  app-only UI; chat-specific UI lives in `RxCodeChatKit`; sync protocol code in
  `RxCodeSync`; app orchestration in `RxCode/`.

See [Data Flow](data-flow) for the request lifecycle, [Services](services) for
the runtime service catalog, [Swift Packages](packages) for package layout, and
the [Relay Server API](../api/relay-server) for the mobile-sync transport.
