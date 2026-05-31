---
slug: architecture/services
title: Runtime Services
description: Catalog of RxCode's agent runtime and supporting services.
---

# Runtime Services

RxCode isolates integrations behind actor-based and service-oriented types under
`RxCode/Services/`. They fall into two groups: agent runtime services that run
and stream from coding agents, and supporting services that back persistence,
search, sync, Git, updates, and platform integrations.

## Agent runtime services

| Service | Role |
| --- | --- |
| `ClaudeService` | Runs Claude Code: process discovery, streaming, summaries, CLI session integration. |
| `CodexAppServer` | Runs Codex app-server sessions; parses protocol events; fetches Codex models and rate limits. |
| `ACPService` | Runs ACP clients (e.g. OpenCode, Gemini CLI); manages pooled sessions, protocol I/O, model discovery, permission bridging. |
| `ACPRegistryService` / `ACPInstallerService` | Fetches ACP registry data and installs compatible ACP client binaries. |
| `PermissionServer` | Local HTTP server for CLI permission hooks and approval handoff to the UI. |
| `MCPService` | Reads, writes, probes, and adapts MCP server configuration for supported agent runtimes. |
| `IDEServer` tools | Exposes project / thread / search / memory tools to agents via the in-app IDE MCP server. |

## Supporting services

| Service | Role |
| --- | --- |
| `PersistenceService` / `ThreadStore` | JSON-backed persistence under Application Support; thread/session storage. |
| `ThreadSearchService` | On-device embedding and natural-language search over chat threads. |
| `MobileSyncService` | E2E-encrypted mobile pairing, relay communication, APNs fan-out, live sync events. |
| `RunService` / `RunProfileDetector` | Run profile execution and detection for Xcode, npm, make, and shell workflows. |
| `GitHubService` | OAuth device flow, Keychain token storage, SSH key management, repo browsing, cloning. |
| `MarketplaceService` | Skill / plugin catalog fetching and installation. |
| `RateLimitService` | Claude usage API polling, OAuth token refresh, usage tracking. |
| `UpdateService` | Sparkle-based update manager. |
| `BashSafety` | Read-only command validation for agent-exposed shell helpers. |

## Implementation guidelines

- Prefer existing services, models, theme tokens, and helpers over new abstractions.
- Avoid blocking the main actor with process, file, network, or parsing work.
- When adding agent features, account for Claude Code, Codex, and ACP behavior
  unless the feature is explicitly provider-specific.
- When changing sync payloads, preserve backward/forward compatibility — mobile
  and desktop versions can differ.
- When changing persistence formats, add migration or tolerant decoding rather
  than assuming fresh data.

See [Data Flow](data-flow) for how these services participate in a request and
[Swift Packages](packages) for the package boundaries they respect.
