# RxAgentSDK Migration

RxCode is moving its agent transport layer onto
[RxAgentSDK](https://github.com/rxtech-lab/RxAgentSDK), which is an extraction
and cleanup of that same layer. The SDK's own source comments name what they
replace (`BackendSendRequest`'s provider-tagged fields, `StreamEvent.unknown`
forcing Codex and ACP to synthesize Claude wire frames), so this is re-adopting
code that already left, not integrating a foreign library.

The migration replaces roughly 5,600 lines of process, protocol and approval
code — `ClaudeService*`, `CodexAppServer*`, `ACPService*`, `PermissionServer` —
while leaving `AppState`, `ThreadStore`, `RxCodeChatKit` and the rest of the app
untouched.

## The seam

Everything routes through the `AgentBackend` protocol in
`RxCodeCore/Backend/AgentBackend.swift`. `AppState.backend(for:)` consults
`agentBackendOverrides` before falling back to the built-in services, so
swapping implementations needs no change at any call site.

```
AppState.send(in:)
  └─ resolveStreamPreflight(…)        MCP config, ACP spec, model/effort, context
       └─ backend(for: provider)      agentBackendOverrides wins
            ├─ ClaudeService / CodexAppServer / ACPService   (legacy)
            └─ SDKAgentBackend                                (RxAgentSDK)
                 └─ AgentEventBridge  AgentEvent → StreamEvent
```

## Status

**Phase 1 — done.** SDK-backed implementations of all three providers exist and
are selectable at runtime. They are **off by default**:

```bash
defaults write com.rxlab.RxCode UseAgentSDK -bool YES
```

A flag rather than a straight swap because the SDK owns process spawning,
approval hooks and MCP rendering, and "does this behave the same?" is only
answerable by running the same thread both ways on the same build.

| File | Role |
| --- | --- |
| `RxCode/Services/AgentSDK/SDKAgentBackend.swift` | `AgentBackend` actor; one turn per `streamId`, which doubles as the SDK's `turnID` |
| `RxCode/Services/AgentSDK/AgentEventBridge.swift` | `AgentEvent` → `StreamEvent`, holding session id / usage / context window for the terminal `ResultEvent` |
| `RxCode/Services/AgentSDK/AgentSDKConversions.swift` | The 15 colliding type names between `RxCodeCore` and `RxAgentCore` |
| `RxCode/Services/AgentSDK/SDKPermissionResolver.swift` | `PermissionResolving` → `PermissionServer.requestDecision` |
| `RxCode/Services/AgentSDK/SDKBackendFactory.swift` | Builds the three clients; ACP resolves per turn from `ACPClientSpec` |

Supporting changes outside that folder:

- `StreamEvent` gained `.textDelta` / `.thinkingDelta` / `.toolCallStarted` /
  `.toolCallInput`. These are the decoded form of what the legacy backends send
  as raw `content_block_*` frames inside `.unknown`. `AppState+Stream.swift`
  factored the handling of those frames into `applyTextDelta`, `beginToolCall`
  and `applyToolCallInput`, which both paths now call — so a Claude turn and an
  SDK turn drive the same state machine.
- `BackendSendRequest` gained `mcpServers` and `ideBridgeCommand`: the same
  servers as the three pre-rendered fields, unrendered, for backends that build
  their own config.
- `AgentBackend` gained `consumeStderr(for:)`, so `consumeAgentStderr` dispatches
  through `backend(for:)` instead of switching on the provider.

### Duplicate type names

`RxCodeCore` and `RxAgentCore` both define `AgentProvider`, `JSONValue`,
`TodoItem`, `PermissionMode`, `PermissionRequest`, `PermissionDecision`,
`UsageInfo`, `ContextWindowInfo`, `RateLimitInfo`, `ToolCategory`,
`MCPServerSpec`, `TodoExtractor`, `CLISessionStore`, `SyntaxHighlighter` and
`PerformanceDiagnostics`.

`RxCode/Services/AgentSDK/` is the only place that imports both, and it
qualifies every ambiguous name. Do not `import RxAgentCore` elsewhere in the app
target until the duplicates are retired.

## Remaining work

1. **Parity testing.** Run the same threads both ways per provider: resume,
   plan mode, `AskUserQuestion`, background tasks, attachments, worktrees,
   mobile sync.
2. **Gaps to close in Phase 2.**
   - Model discovery still comes from the legacy services' `availableModels`
     paths, not `AgentClient.availableModels()`. Reasoning levels *are* wired:
     `AgentBackend.availableReasoningLevels()` is answered statically by the
     legacy backends and forwarded to the SDK client by `SDKAgentBackend`. See
     [reasoning-levels.md](reasoning-levels.md).
   - `modelsDiscovered` is tagged with a fixed `ACPModelConfig.configId`, which
     is enough to render the picker but not to switch models live. Wiring that
     back up needs the id plumbed through `AgentEvent`.
   - `BackendCapability` (RxCode) and `AgentCapability` (SDK) are not
     translated; SDK backends declare RxCode's static sets. The former drives
     which IDE MCP polyfills get exposed, so mistranslating it silently changes
     the tool surface.
   - Codex config overrides and ACP `session/new` MCP payloads are still
     rendered by `MCPService` for the legacy path; the SDK renders its own from
     `mcpServers`.
   - `SDKAgentBackend.steer` declines. The pinned SDK release has no steering
     entry point on `AgentClient`; since `streamId` is already the SDK's
     `turnID`, it is a one-line forward once that ships. See
     [steering.md](steering.md).
3. **Retire the legacy layer.** Delete `ClaudeService*`, `CodexAppServer*`,
   `ACPService*` and `PermissionServer`; drop `StreamEvent.unknown` and
   `handlePartialEvent(_:for:)`; collapse the duplicate `RxCodeCore` types into
   re-exports of `RxAgentCore`; remove the `UseAgentSDK` flag.
4. **Adopt `AgentChatUI`.** Blocked on the duplicate types above — see below.

## UI adoption

The SDK ships four SwiftUI modules. Two of them are now the app's renderers and
the local copies are gone:

| Was | Is now |
| --- | --- |
| `Packages/Sources/MessageList/` | `AgentMessageListUI` |
| `Packages/Sources/RxCodeMarkdown/` | `AgentMarkdownUI` |

Both were straight extractions of the local code — `MarkdownDocumentParser.swift`
was byte-identical, and `AgentMessageListUI` is the local `MessageList` made
`public` and then moved *ahead* of it (`bottomInset`, the reserved tail spacer,
`MessageListTurnMeasurement`). The only call-site change was the import in
`ChatTranscriptList.swift` and `RxCodeChatKit/MarkdownView.swift`; the
`MessageList(...)` init is source-compatible because `bottomInset` defaults.
`Packages/Tests/MessageListTests` and `RxCodeMarkdownTests` were deleted, not
ported: the SDK's `AgentMessageListUITests` and `AgentMarkdownUITests` are a
strict superset of them.

These two are safe to depend on because they import only `RxAgentUISupport`, so
they dodge the duplicate-type problem entirely.

`AgentChatUI` is a different matter and is **not** adopted:

- It depends on `RxAgentCore`, which means adopting it re-opens all 15 name
  collisions across the whole UI layer rather than inside
  `RxCode/Services/AgentSDK/`. Its views bind to `RxAgentCore` models, so the
  swap is a model-layer migration, not a view swap.
- It is a generic agent chat surface. `RxCodeChatKit` is ~10.7k lines carrying
  plan cards, todo progress, slash commands, shortcuts, CI status, ACP pickers,
  bash terminal sheets, file/change diffs and review countdowns, none of which
  have an `AgentChatUI` equivalent.

Adopting it belongs after step 3 (collapsing the duplicate types), not before.

### Split performance counters

`RxAgentUISupport.PerformanceDiagnostics` is a byte-identical copy of
`RxCodeCore.PerformanceDiagnostics` — and a *separate* static accumulator. The
`scroll.*` and `markdown.*` keys now land in the SDK's registry, so
`PerformanceDiagnosticsService.drainEvents()` drains both and merges them
through `PerformanceDiagnostics.Snapshot.merging(counters:measurements:)`. The
record's JSON shape is unchanged. Collapse this when the duplicate types are
retired.

## Dependency

Pinned to `1.0.4` (up to next minor) in `RxCode.xcodeproj` **and** in
`Packages/Package.swift`, which also raised the package platforms to
macOS 26 / iOS 26 to match the SDK. Note that local RxAgentSDK work ahead of
that tag is not picked up until it is tagged and pushed — add a local package
reference in Xcode while developing both together.
