# Steering a running turn

Sending a message while an agent is mid-turn used to mean one of two things:
the message went into a queue and waited for the turn to end, or — if the user
picked "send now" on a queued message — RxCode cancelled the turn and started a
new one. The second is destructive: whatever the agent had in flight is thrown
away, and the thread restarts from the last resume point.

Both Claude Code and Codex can take extra user input *into* a running turn, so
there is now a third option, and the user picks between all three.

## Queue first, then the user decides

Sending mid-turn always queues. Nothing reaches the agent until the user says
when, and doing nothing is a real answer — the queue flushes on its own when the
turn ends (`flushNextQueuedMessageIfNeeded`, at the tail of
`finalizeStreamSession`).

The queued row is where the default gets overridden:

| Choice | What happens | Cost |
| --- | --- | --- |
| *(leave it)* | sent as a new turn once the current one finishes | none |
| **Steer into current response** | handed to the turn already running, which keeps going | none, when the turn takes it |
| **Interrupt and send now** | the running turn is cancelled, the message starts a new one | whatever the agent had in flight |

"Steer all into current response" and "Interrupt and send all now" are the same
pair applied to the whole queue, joined with blank lines into one message.

The steer action is offered only when `ChatBridge.canSteer` is true — that is,
when the session's backend declares `supportsSteering` — and only for messages
with no attachments. Everything else gets the plain interrupt button, which is
what this looked like before steering existed.

## Per-provider transport

| Provider | Mechanism | Notes |
| --- | --- | --- |
| Claude Code | another `{"type":"user",…}` NDJSON frame on the open stdin | `--input-format stream-json` already keeps stdin open until `closeStdin(streamId:)`, so there is no new transport — just one more write on the handle we were holding |
| Codex | `turn/steer` JSON-RPC request | Needs `threadId` + `expectedTurnId`; the app server rejects the request if the turn ended first |
| ACP | none | The protocol has no equivalent, so `steer` declines and the message queues |
| RxAgentSDK | not yet | `AgentClient` in the pinned release has no steering entry point — see [rxagentsdk-migration.md](rxagentsdk-migration.md) |

Codex's turn id comes from the `turn/started` notification (`params.turn.id`),
which RxCode now records in `CodexAppServer.activeTurns` and clears on
`turn/completed` / `turn/failed`. The presence of that record is what makes
`steer` decline rather than write into a turn the app server has already closed.

## The contract

Two requirements, because the UI and the write need different answers:

- `AgentBackend.supportsSteering: Bool` (default `false`, `nonisolated`) — can
  this transport reach a running turn *at all*? Read from the bridge push loop
  on every streaming update, which is why it is synchronous.
- `AgentBackend.steer(streamId:prompt:) async -> Bool` (default `false`) — did
  *this* turn take it? Only knowable at the moment of the write.

Returning `false` from `steer` is normal, not an error — the turn may have
finished between the click and the write landing. **A caller that gets `false`
still owes the user their message**, so every call site has a fallback:

| Call site | On `true` | On `false` |
| --- | --- | --- |
| "Steer now" on a queued message (`steerQueuedMessage`) | delivered, that one message leaves the queue | stays queued; if the turn had already ended, sent now instead |
| "Steer all" (`steerAllQueuedAsOne`) | joined with blank lines, delivered as one | whole queue stays intact, same end-of-turn fallback |
| "Interrupt and send now" (`sendQueuedNow` / `sendAllQueuedAsOne`) | — | never steers; cancels the turn and sends as a new one |

A declined steer leaves the message exactly where it was, so the worst case is
the default behaviour. The queued row says so inline rather than letting the
click look like a no-op.

## Transcript

A steered message never passes through `sendPrompt`, which is what normally
appends the user bubble — so `steerActiveStream` appends it directly and sets
`needsNewMessage`, which makes the agent's next delta open a fresh bubble
instead of extending the one it was part-way through writing.

## Attachments are not steered

Both transports can carry attachments in principle, but the encoding differs per
provider. Rather than risk one being silently dropped mid-turn, a message
carrying any attachment declines to steer — the UI doesn't offer the action for
it, and `steerActiveStream` refuses it even if asked.
Lifting this means encoding attachments per provider — Claude's `content` array
takes image blocks, Codex's `UserInput` has image and file variants.

## Files

| File | Role |
| --- | --- |
| `Packages/Sources/RxCodeCore/Backend/AgentBackend.swift` | `steer` requirement + declining default |
| `RxCode/Services/ClaudeService+Process.swift` | stdin frame |
| `RxCode/Services/CodexAppServer.swift` | `turn/steer` + `activeTurns` |
| `RxCode/Services/CodexAppServer+Turn.swift` | captures / clears the live turn id |
| `RxCode/App/AppState+Steering.swift` | `steerActiveStream`, `steerQueuedMessage`, `steerAllQueuedAsOne`, `canSteer`, transcript append |
| `RxCode/App/AppState+Helpers.swift` | `enqueueMessage` + the interrupting `sendQueuedNow` / `sendAllQueuedAsOne` |
| `Packages/Sources/RxCodeChatKit/ChatBridge.swift` | `canSteer` state + the steer handlers |
| `Packages/Sources/RxCodeChatKit/InputBarView+Queue.swift` | the queued row's send menu |
| `RxCodeTests/AppStateSteeringTests.swift` | decision-logic coverage |
