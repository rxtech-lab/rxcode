# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RxCode is a native macOS desktop client for the Claude Code CLI. Written in Swift + SwiftUI with two external dependencies: SwiftTerm (terminal emulation) and Sparkle (auto-update).

## Writing Rules

- All text committed to the project — code comments, commit messages, PR descriptions, log messages — must be written in **English**.

## Build & Run

```bash
# Open in Xcode (build/run with Cmd+R)
open RxCode.xcodeproj

# CLI build
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug build

# Release build
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Release build
```

- Minimum deployment target: macOS 26.0+
- No test suite (UI app)
- Bundle ID: `com.idealapp.RxCode`
- External dependencies: SwiftTerm (terminal emulation), Sparkle (auto-update)

## Architecture

### Core Patterns

- **Observable AppState** (`App/AppState.swift`): `@MainActor @Observable` single state container. Manages all app state including projects, sessions, chat, and permission approvals.
- **App entry point** (`App/RxCodeApp.swift`): Defines WindowGroup (main), WindowGroup(id: "project-window") for dedicated per-project windows, Settings window, and Command menu (theme, update).
- **Actor-based services**: All services are implemented as `actor` for concurrency safety. Isolated without locks.
- **SwiftUI only**: No Storyboards or XIBs. 100% declarative UI.

### Package Structure

The codebase is split into two Swift packages under `Packages/`:

| Package         | Role                                                             |
| --------------- | ---------------------------------------------------------------- |
| `RxCodeCore`    | Shared models, theme, utilities — no UI dependencies             |
| `RxCodeChatKit` | Chat UI components (ChatView, MessageBubble, InputBarView, etc.) |

### Service Layer (`Services/`)

| Service              | Role                                                                                                                                            |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `ClaudeService`      | Spawns Claude CLI as a subprocess, parses stdout NDJSON stream, buffers text deltas at 50ms intervals                                           |
| `PermissionServer`   | Network framework-based local HTTP server (ports 19836–19846). Receives CLI PreToolUse hook requests and holds the connection until UI approval |
| `GitHubService`      | OAuth Device Flow authentication, Keychain token storage, SSH key generation/registration, repo cloning                                         |
| `PersistenceService` | JSON file-based persistence at `~/Library/Application Support/RxCode/`. Per-project/session directory structure                                 |
| `MarketplaceService` | Parallel fetch of plugin catalog from 4 Anthropic GitHub repos, 5-minute cache                                                                  |
| `RateLimitService`   | Anthropic usage API polling, OAuth token refresh, usage tracking                                                                                |
| `UpdateService`      | Sparkle-based auto-update manager. Starts updater on launch; exposes `checkForUpdates()` for menu-initiated checks                              |
| `BashSafety`         | Whitelist-based read-only command validator. Blocks mutating git/claude/npm subcommands and write redirections                                  |

### Data Flow

1. User input → `AppState.send()` → `ClaudeService.send()` spawns CLI subprocess
2. CLI stdout → NDJSON `AsyncStream<StreamEvent>` → per-event processing in `processStream()`
3. Text deltas buffered at 50ms intervals to prevent SwiftUI update thrashing
4. On tool execution: PermissionServer receives HTTP request → UI approval modal → returns response
5. On project switch: in-progress stream detached to background Task, saved to disk on completion

### View Structure (`Views/`)

- `MainView`: NavigationSplitView (sidebar + detail) with project tab bar
- `ProjectWindowView`: Dedicated single-project window (opened by double-clicking a project tab)
- `SettingsView`: App settings window (model defaults, appearance, etc.)
- `Chat/`: Main chat UI, message streaming, slash commands, attachments, marketplace, file diff, status line
- `Sidebar/`: Project list, session history, file tree, Git status, file preview, GitHub repo list
- `Onboarding/`: Initial setup flow, GitHub login
- `Permission/`: Risk-based (Safe/Moderate/High) tool approval modals
- `Terminal/`: SwiftTerm-based built-in terminal
- `UserManualView`: In-app user guide (Help menu). NavigationSplitView with topic list and detail. Topics: overview, projects, chat, shortcuts, slash commands, attachments, shortcut buttons, terminal, marketplace, permissions
- `InspectorMemoPanel`: Sidebar inspector panel with a rich-text (NSTextView) memo editor, persisted per project

### Compiler Settings

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — default MainActor isolation
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- App Sandbox disabled (required for system integration)

### Theme

`Theme/ClaudeTheme.swift` + `Theme/AppTheme.swift` — terracotta accent (#D97757), light/dark mode, color palette, typography, corner radius constants (8/12/16/20)
