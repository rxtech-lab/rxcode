# AGENTS.md

This file is the canonical guidance for coding agents working in this repository. Use English for all responses and all committed project text.

## Project Overview

RxCode is a native macOS desktop client for AI coding agents. It is written in Swift and SwiftUI, with a project-centric UI for Claude Code, Codex, and Agent Client Protocol (ACP) clients. The app includes streaming chat, permission approval flows, run profiles, Git worktree support, natural-language thread search, mobile sync, and briefing/change tracking.

The main app target is a macOS app. The repository also contains shared Swift packages, widget/mobile-related code, website assets, and release tooling.

## Writing Rules

- Write code comments, log messages, commit messages, PR descriptions, documentation, and user-facing text in English.
- Keep documentation factual and current. Prefer removing duplicated guidance over maintaining the same instructions in multiple files.
- Preserve user changes. Do not revert unrelated local edits unless the user explicitly asks for that.

## Build And Run

```bash
# Open in Xcode
open RxCode.xcodeproj

# Debug build
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug build

# Release build
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Release build

# Swift package build
swift build --package-path Packages

# Swift package tests
swift test --package-path Packages
```

Project notes:

- macOS app deployment target: macOS 26.0+
- Swift tools version: 6.2
- Main app bundle ID: `com.rxlab.RxCode`
- App-level dependencies: SwiftTerm and Sparkle
- Package dependencies: ViewInspector

## Repository Layout

| Path | Purpose |
| --- | --- |
| `RxCode/` | macOS app target: app entry point, SwiftUI views, services, resources, and integrations. |
| `RxCode/App/` | `AppState`, app lifecycle, session handling, streaming, project/worktree logic, mobile sync dispatch, and agent coordination. |
| `RxCode/Services/` | Actor-based and service-oriented integrations for agents, permissions, GitHub, persistence, mobile sync, search, MCP, updates, and run profiles. |
| `RxCode/Views/` | SwiftUI UI surfaces: main workspace, chat, sidebar, inspector, settings, terminal, permissions, search, run profiles, and onboarding. |
| `Packages/Sources/RxCodeCore/` | Shared models, theme, utilities, run profile models, Git helpers, CLI session parsing, backend contracts, and reusable non-app UI primitives. |
| `Packages/Sources/RxCodeChatKit/` | Reusable chat UI, message rendering, input bar, slash commands, shortcuts, diffs, queue UI, and plan/question views. |
| `Packages/Sources/RxCodeSync/` | End-to-end encrypted sync protocol, pairing, APNs alert payloads, and mobile/desktop transport data structures. |
| `RxCodeWidget/` | Widget and Live Activity support for active work and usage information. |
| `RxCodeTests/`, `RxCodeUITests/` | App-level XCTest and UI test coverage. |
| `Packages/Tests/` | Swift package tests for core, chat kit, and sync logic. |
| `website/` | Public website and screenshot assets. |
| `scripts/` | Build, signing, notarization, Sparkle, and release automation. |

## Architecture

### Core Patterns

- **Observable app state**: `RxCode/App/AppState.swift` is a `@MainActor @Observable` state container. Behavior is split across `AppState+*.swift` extensions by domain.
- **SwiftUI-only UI**: Use SwiftUI views. Do not introduce Storyboards or XIBs.
- **Actor-based services**: Services that own mutable shared state should be actors or should clearly isolate concurrency through existing patterns.
- **Backend abstraction**: Claude Code, Codex, and ACP flows share backend contracts from `RxCodeCore/Backend`. Avoid adding agent-specific branches when the shared protocol can express the behavior.
- **Package boundaries**: Keep `RxCodeCore` broadly reusable and free of app-only UI dependencies. Put chat-specific SwiftUI components in `RxCodeChatKit`, sync protocol code in `RxCodeSync`, and app orchestration in `RxCode/`.

### Agent Runtime Services

| Service | Role |
| --- | --- |
| `ClaudeService` | Runs Claude Code, handles process discovery, streaming, summaries, and CLI session integration. |
| `CodexAppServer` | Runs Codex app-server sessions, parses protocol events, fetches Codex models and rate limits. |
| `ACPService` | Runs ACP clients such as OpenCode or Gemini CLI, manages pooled ACP sessions, protocol I/O, model discovery, and permission bridging. |
| `ACPRegistryService` / `ACPInstallerService` | Fetches ACP registry data and installs compatible ACP client binaries. |
| `PermissionServer` | Local HTTP server for CLI permission hooks and approval handoff to the UI. |
| `MCPService` | Reads, writes, probes, and adapts MCP server configuration for supported agent runtimes. |
| `IDEServer` tools | Exposes project/thread/search/memory tools to agents through the in-app IDE MCP server. |

### Supporting Services

| Service | Role |
| --- | --- |
| `PersistenceService` / `ThreadStore` | JSON-backed persistence under Application Support and thread/session storage. |
| `ThreadSearchService` | On-device embedding and natural-language search over chat threads. |
| `MobileSyncService` | E2E encrypted mobile pairing, relay communication, APNs fan-out, and live sync events. |
| `RunService` / `RunProfileDetector` | Run profile execution and detection for Xcode, npm, make, and shell workflows. |
| `GitHubService` | OAuth device flow, Keychain token storage, SSH key management, repository browsing, and cloning. |
| `MarketplaceService` | Skill/plugin catalog fetching and installation support. |
| `RateLimitService` | Claude usage API polling, OAuth token refresh, and usage tracking. |
| `UpdateService` | Sparkle-based update manager. |
| `BashSafety` | Read-only command validation for agent-exposed shell helpers. |

## Data Flow

1. User input enters `AppState.send(in:)`.
2. `AppState` resolves the selected agent provider, model, effort, permission mode, working directory, and optional worktree.
3. The selected backend (`ClaudeService`, `CodexAppServer`, or `ACPService`) emits an `AsyncStream<StreamEvent>`.
4. `AppState+Stream.swift` processes stream events, updates chat state, tracks tools, handles permission requests, and persists messages.
5. Permission requests route through the UI and, where needed, through `PermissionServer` or ACP/Codex protocol responses.
6. Thread summaries, branch briefings, change tracking, search indexes, widgets, and mobile snapshots update from persisted session state.

## UI Areas

- `MainView`: main `NavigationSplitView` workspace.
- `ProjectWindowView`: dedicated single-project windows.
- `Chat/` and `RxCodeChatKit`: message list, input, slash commands, attachments, plans, questions, tool output, diffs, and status UI.
- `Sidebar/`: projects, session history, briefing, file tree, Git status, GitHub repo list, and file previews.
- `Inspector/`: changes, this-thread diff, and right-side contextual panels.
- `RunProfile/`: run configuration editor, toolbar controls, and command output inspector.
- `Settings/`: agent, ACP, MCP, mobile sync, commands, memory, appearance, and related settings.
- `Terminal/`: SwiftTerm-based terminal UI.
- `Permission/`: risk-aware approval modals and queued permission banners.
- `Search/`: global natural-language search overlay.

## Implementation Guidelines

- Prefer existing app services, models, theme tokens, and helper utilities over new abstractions.
- Keep UI consistent with the established SwiftUI style and `ClaudeTheme` / `AppTheme` tokens.
- Avoid blocking the main actor with process, file, network, or parsing work.
- When adding agent features, consider Claude Code, Codex, and ACP behavior unless the feature is explicitly provider-specific.
- When changing sync payloads, preserve backward/forward compatibility where possible because mobile and desktop versions can differ.
- When changing persistence formats, add migration or tolerant decoding rather than assuming all users have fresh data.
- Use `rg` for code search and inspect surrounding code before editing.

## Testing Expectations

- For package logic, run focused `swift test --package-path Packages` tests when practical.
- For app changes, prefer focused XCTest/UI test runs if the touched area has coverage.
- For build-sensitive changes, run `xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug build`.
- If you cannot run the relevant verification, state that clearly in the final response.

## Compiler And Platform Settings

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is enabled for the app and relevant targets.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` is enabled for app/mobile-related targets.
- App Sandbox is disabled for the main macOS app because RxCode integrates with local developer tools and projects.
