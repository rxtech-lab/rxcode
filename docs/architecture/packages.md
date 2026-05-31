---
slug: architecture/packages
title: Swift Packages
description: Package boundaries for RxCodeCore, RxCodeChatKit, and RxCodeSync.
---

# Swift Packages

Shared logic lives in a local Swift package under `Packages/` (Swift tools
version 6.2). Keeping these packages free of app-only dependencies allows them
to be reused across the macOS app, widgets, and mobile targets.

```bash
# Build the package
swift build --package-path Packages

# Run package tests
swift test --package-path Packages
```

## Package boundaries

| Package | Path | Responsibility |
| --- | --- | --- |
| `RxCodeCore` | `Packages/Sources/RxCodeCore/` | Shared models, theme, utilities, run-profile models, Git helpers, CLI session parsing, backend contracts, and reusable non-app UI primitives. Must stay broadly reusable and free of app-only UI dependencies. |
| `RxCodeChatKit` | `Packages/Sources/RxCodeChatKit/` | Reusable chat UI: message list, input bar, slash commands, shortcuts, diffs, queue UI, plan/question views. |
| `RxCodeSync` | `Packages/Sources/RxCodeSync/` | End-to-end encrypted sync protocol, pairing, APNs alert payloads, and mobile/desktop transport data structures. |

Additional UI helper sources live alongside under `Packages/Sources/`
(`DiffView`, `MessageList`).

## Boundary rules

- Put chat-specific SwiftUI components in `RxCodeChatKit`, not `RxCodeCore`.
- Put sync protocol code in `RxCodeSync`; keep transport types
  forward/backward compatible because paired desktop and mobile versions differ.
- Keep app orchestration (`AppState`, services) in the `RxCode/` app target, not
  in the packages.
- Backend contracts shared by Claude Code, Codex, and ACP belong in
  `RxCodeCore/Backend` so the app can avoid agent-specific branches.

## Testing

Package tests live under `Packages/Tests/` covering core, chat kit, and sync
logic. Run focused `swift test --package-path Packages` tests when practical for
package-level changes.

See [Architecture Overview](overview) for how the packages relate to the app
targets and [Runtime Services](services) for the app-side consumers.
