# Thinking / reasoning levels

The composer's effort picker used to offer one hardcoded list —
`low / medium / high / xhigh / max` — to every provider. Those are Claude's.
Codex accepts `minimal / low / medium / high` and rejects the other two, so a
Codex user was shown two levels that could not work and denied one that could.
The levels now come from the provider.

## Where they come from

`AgentBackend.availableReasoningLevels() async -> [ReasoningLevel]`, defaulting
to `[]`.

| Backend | Levels |
| --- | --- |
| `ClaudeCodeServer` | `.claudeCodeEfforts` — what `claude --effort` accepts |
| `CodexAppServer` | `.codexEfforts` — what `model_reasoning_effort` accepts |
| `ACPService` | none. ACP has no standard reasoning control |
| `SDKAgentBackend` | forwards to `AgentClient.availableReasoningLevels()` |

An empty list is how a provider says "I have no reasoning control", and the
picker responds by hiding itself rather than rendering an empty menu.

`ReasoningLevel` (in `RxCodeCore`) mirrors `RxAgentCore.AgentReasoningOption`
and is converted in `AgentSDKConversions.swift` — the same arrangement as the
other duplicated types, because `RxCodeCore` is what the UI imports and it does
not depend on the SDK.

## How they reach the agent

| Provider | Wire form |
| --- | --- |
| Claude Code | `--effort <id>` |
| Codex | `-c model_reasoning_effort="<id>"`, appended to the turn's config overrides |
| ACP | nothing — no level to send |

Codex previously ignored `BackendSendRequest.effort` entirely, so its picker was
inert. `CodexAppServer.effortOverrides(_:)` now emits the override, and **drops
any value Codex doesn't accept**: codex rejects the whole config on a bad enum,
so forwarding a stale `max` from a thread that used to run on Claude would fail
the turn outright rather than merely ignoring the setting.

## Sanitizing before the send

Effort is chosen in places that don't know which agent will run — the Settings
default spans every provider, and a session carries its pick across a provider
switch — so a value can be valid where it was chosen and invalid by the time it
is sent.

`sanitizedEffort(_:for:)` is the single guard, applied in
`resolveStreamPreflight`, which is upstream of the one `BackendSendRequest`
construction site. Every send path funnels through it: foreground, queued and
background sends, cross-project sends, and MCP-driven turns. It drops a level
the provider doesn't accept rather than substituting one — `nil` means "the
agent's own default", which is the honest reading.

Unlike `reconcileSessionEffort(in:provider:)`, it **awaits** the level list
instead of skipping on a cold cache: a send can't be deferred, and treating
"not loaded" as "accepts nothing" is exactly what the guard exists to prevent.

Without it, a global default of `minimal` would reach Claude as
`--effort minimal`, and a stale `max` would reach codex and fail its whole
config. `CodexAppServer.effortOverrides(_:)` keeps its own local guard as a
second line of defence for the wire format.

## Caching and reconciling

Levels are a property of the agent binary, not of a thread, so
`AppState.reasoningLevelsByProvider` caches one answer per provider.
`loadReasoningLevels(for:)` fills it; both the composer picker and the ⌘ sheet
call it, since either can be the first to need it.

`reconcileSessionEffort(in:provider:)` clears a session's effort when the new
provider doesn't accept it — switching Claude → Codex with `max` selected falls
back to Auto. It deliberately does *nothing* when the cached list is empty:
empty means "not loaded yet", and discarding the user's pick on that would lose
it on every launch.

## Scope of each entry point

| Entry point | List |
| --- | --- |
| Composer picker (`ChatToolbarControls`) | the thread's provider |
| ⌘ picker sheet (`EffortPickerSheet`) | the thread's provider |
| `/effort <level>` | validated against the thread's provider, awaiting the level list first so a cold cache can't reject a valid level; anything else resets to Auto |
| Settings → default effort | `AppState.availableEfforts`, the union — this is chosen before any provider is known, and is the only place the union is correct |
