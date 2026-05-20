# RxCode

**The terminal was for the few. RxCode is for everyone.**

RxCode is a lightweight native macOS desktop client for Claude Code, Codex, and Agent Client Protocol (ACP) clients such as Gemini CLI and OpenCode. It brings the CLI agent workflow into a project-centric GUI with streaming chat, repository switching, file browsing, Git status, permissions, terminal access, and per-project notes.

![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.x-orange)
![Version](https://img.shields.io/badge/version-1.2.0-blue)
![License](https://img.shields.io/badge/license-Apache%202.0-green)

---

## Screenshots

![RxCode Screenshot](docs/screenshot.png)

---

## Why RxCode?

The terminal is a wall. For most people who aren't developers, it's a closed door — install a CLI, generate SSH keys, approve every tool call without a real preview of what it's about to do. None of that is hard for engineers; all of it is hard for everyone else. The terminal was for the few, and it still is.

RxCode was built so my non-developer coworkers could use Claude Code, Codex, and ACP-compatible clients without learning a shell first. It doesn't reinvent the agent. It talks to the real runtimes underneath: `claude` for Claude Code, the Codex app-server through the `codex` CLI for Codex sessions, and ACP clients installed from the public registry. Your existing CLI setup stays the source of truth when you bring your own runtime. What sits on top is a native Mac app:

- Approval modals that surface the actual diff before any tool runs, with risk-aware Allow / Allow Session / Deny options.
- Per-project windows you can run in parallel — switch tabs, double-click to spin off a window, keep streams alive in the background.
- Drag-and-drop attachments, smart paste for images, file paths, URLs, and long text.
- GitHub OAuth that handles SSH key setup for you, so `git clone` just works.
- An inspector with a file tree, Git status, embedded terminal, and a per-project memo pad.

Same agents, no terminal required.

---

## What RxCode Adds

| RxCode feature | Why it matters |
|---------------|----------------|
| **Native macOS app** | Built with SwiftUI, not Electron. The current v1.2.0 release is about 5.6 MB to download and about 13 MB unpacked, without bundling a browser runtime. |
| **Claude Code, Codex, and ACP support** | Choose the agent runtime per session. RxCode detects installed `claude` and `codex` binaries, surfaces available models, and also runs ACP-compatible clients such as Gemini CLI and OpenCode. |
| **ACP registry installer** | Browse the public ACP registry from Settings, install compatible clients directly, and add registry agents to the chat model picker without manual setup. |
| **Project-centric workspace** | Register multiple local repositories, switch between them from project tabs, or open a project in its own window for parallel sessions. In-progress streams keep running in the background while you switch. |
| **Custom slash commands** | Add, edit, disable, import, and export custom slash commands. Built-in commands can be edited locally, while JSON import/export stays custom-only. |
| **Shortcut buttons** | Create quick buttons for prompts or terminal commands you run repeatedly. Terminal-command shortcuts can launch directly into RxCode's interactive terminal popup. |
| **Built-in file explorer with Git status** | Browse and search project files, toggle hidden files, preview or edit files, inspect Git status, and switch branches from the sidebar. |
| **Rich-text memo pad per project** | Keep project-specific notes in the inspector panel with headings, lists, checkboxes, links, and Markdown copy/paste support. |
| **Embedded terminal** | Use a SwiftTerm-based terminal in the inspector, plus interactive terminal popups for commands such as `/config`, `/permissions`, and `/model`. |

---

## Features

| Feature | Description |
|---------|-------------|
| **Streaming Chat** | Real-time Claude Code, Codex, and ACP client conversations with Markdown rendering, tool call visualization, diff views, and error bubbles for failed empty responses. |
| **Multi-Project Workspace** | Register local folders or GitHub repositories, switch freely, and keep per-project session history. |
| **Dedicated Project Windows** | Double-click a project tab to open it in an independent window and work across multiple repositories at once. |
| **Per-Session Controls** | Choose model, permission mode, and effort level per session from the chat toolbar. Defaults are configurable in Settings. |
| **Permission Modes** | Ask, Accept Edits, Plan, Auto, and Bypass modes mirror Claude Code's permission model and can be changed from the toolbar. |
| **Permission Management** | Risk-based approve/deny UI with Allow, Allow Session, Deny, and 5-minute auto-deny handling. |
| **Effort Levels** | Auto, Low, Medium, High, XHigh, and Max reasoning controls for each session. |
| **Model Selection** | Claude Code aliases, Codex models, and ACP-advertised models with localized descriptions, including Opus, Sonnet, Haiku, 1M context, plan variants, GPT coding models, and client-provided model lists. |
| **File Attachments** | Drag-and-drop files and images. Smart paste detects images, file paths, URLs, and long text. |
| **Attachment Auto-Preview Settings** | Toggle automatic preview chips separately for URLs, file paths, images, and long text. |
| **Slash Commands** | Built-in and custom command system with built-in command edits/toggles and custom-command JSON import/export. |
| **Shortcut Buttons** | Configurable quick-access buttons for frequent prompts and terminal commands. |
| **Message Queue** | Queue messages while Claude is responding; cancel queued items with ESC or the remove button. |
| **Status Line** | Project path, model, 5-hour and 7-day rate limits, context usage, and response time at a glance. |
| **Built-in Terminal** | SwiftTerm-powered inspector terminal with reset support, plus full interactive terminal sheets. |
| **File Explorer** | Project file tree with search, hidden-file toggle, syntax-highlighted preview, file editing, and `@path` insertion. |
| **Git Status** | Sidebar Git status summary with changed-file counts, branch display, and local/remote branch switching. |
| **GitHub Integration** | OAuth device flow, Keychain token storage, SSH key management, repository browsing, and cloning. |
| **Memo Panel** | Per-project rich-text memo pad with headings, lists, checkboxes, links, and persistent storage. |
| **Skill Marketplace** | Browse and install OpenAI Agent Skills and compatible skill catalogs from Settings, refreshed with a 5-minute cache and enabled for supported coding agents. |
| **Themes and Font Controls** | Six accent themes plus independent font size controls for the interface and message area. |
| **Focus Mode** | Optional focused chat layout that can be enabled from Settings. |
| **Notifications** | Optional system notifications with response previews while RxCode is in the background. |
| **Localization** | Full English and Korean UI. |
| **User Guide** | Built-in in-app help guide accessible from the toolbar and Settings. |
| **Auto-update** | Sparkle-based update checking on launch, with manual checks from the app menu. |

---

## Requirements

- **macOS 26.0** or later
- At least one supported agent runtime installed and authenticated:
  - **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)**
  - **Codex CLI**
  - **ACP-compatible clients**, installed from Settings -> ACP Clients -> Registry or configured externally
- **Xcode with Swift 6.2+ toolchain** for building the current source tree

---

## Installation

1. Download the latest `RxCode-x.y.z.zip` from the [Releases](https://github.com/ttnear/RxCode/releases) page.
2. Unzip and move `RxCode.app` to your `Applications` folder.
3. Launch `RxCode.app`.

### First Launch on macOS 26

macOS 26 blocks the first launch of any downloaded app, even notarized ones, and routes approval through System Settings instead of the old right-click -> Open flow.

When you see **"Apple could not verify 'RxCode.app' is free of malware..."**:

1. Click **Done** on the dialog.
2. Open **System Settings -> Privacy & Security**.
3. Scroll to the Security section and click **Open Anyway** next to `RxCode.app`.
4. Confirm with your password or Touch ID.

After this one-time approval, RxCode launches normally. The app is signed with a Developer ID certificate and notarized by Apple. This prompt is standard macOS behavior, not a security warning specific to RxCode.

---

## Build from Source

```bash
open RxCode.xcodeproj
```

For a CLI build:

```bash
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug build
```

For tests:

```bash
xcodebuild test -project RxCode.xcodeproj -scheme RxCode -destination 'platform=macOS'
swift test --package-path Packages
```

For a signed release ZIP, use the release scripts under `scripts/`.

---

## Project Structure

| Path | Purpose |
|------|---------|
| `RxCode/` | macOS app target: app entry point, views, services, resources, and integrations. |
| `Packages/Sources/RxCodeCore/` | Shared models, theme, utilities, Git helpers, and pure core logic. |
| `Packages/Sources/RxCodeChatKit/` | Reusable chat UI, message rendering, input bar, slash commands, shortcuts, diffs, and status line. |
| `RxCodeTests/` | App-level XCTest coverage. |
| `Packages/Tests/` | Swift Testing coverage for core utilities. |
| `release_notes/` | Human-readable release notes used for publishing. |
| `scripts/` | Build, notarization, Sparkle signing, and release automation. |

---

## License

Apache License 2.0. See the [LICENSE](LICENSE) file for details.
