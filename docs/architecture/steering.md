# Steering a running turn

Sending during a response queues the instruction. The queued row lets the user steer
the active response when the agent supports it, or explicitly interrupt and send.
Leaving the instruction queued sends it in order when the turn finishes. The Mac chat
also offers these choices for the whole queue, joined into one instruction.

| Runtime | Steering transport |
| --- | --- |
| Claude Code | A user frame on the running CLI’s stream-json input |
| Codex | `turn/steer` with the current thread ID and expected turn ID |
| ACP v1 | An experimental extension negotiated with the running adapter |

## ACP v1

The standard v1 `session/prompt` response marks the end of that prompt. RxCode
keeps one prompt in flight per session and holds queued instructions locally.
Interrupt and Send sends `session/cancel`, answers outstanding permission
requests with `cancelled`, and waits for the original request’s terminal response.
The next prompt reuses the same process and ACP session ID. If cancellation
cannot be confirmed with the current connection, the selected instruction
stays queued. [ACP v1 prompt turn and cancellation](https://agentclientprotocol.com/protocol/v1/prompt-turn#cancellation)

When `initialize` reports `_meta.steering.supported: true`, RxCode checks the
adapter identity and version for support of host-owned idle fallback. The known
versions are `@agentclientprotocol/codex-acp` 2.4.0 and later 2.x releases, and
`@agentclientprotocol/claude-agent-acp` 0.65.0 and later 0.x releases. The
capability appears on the active turn after negotiation. Older and unknown
adapters offer Interrupt and Send. [ACP extensibility](https://agentclientprotocol.com/protocol/v1/extensibility) · [Codex ACP steering](https://github.com/agentclientprotocol/codex-acp/blob/v2.4.0/docs/steering.md) · [Claude ACP idle fallback](https://github.com/agentclientprotocol/claude-agent-acp/pull/919) · [Claude ACP turn lifecycle fix](https://github.com/agentclientprotocol/claude-agent-acp/releases/tag/v0.65.0)

RxCode calls `_session/steering` with `_meta.steering.idleBehavior: "promptRequired"`.
An `injected` receipt places the instruction in the transcript and keeps the
original prompt as the owner of subsequent output. The host holds incoming
updates behind the receipt and ignores echoed user chunks, so the instruction
appears once before the response to it. A `promptRequired` receipt leaves the
instruction queued for a normal prompt. A missing or ambiguous receipt shows
the instruction with a delivery warning and prevents automatic replay.
Attachments travel as path references, using the same encoding as a normal
prompt.

## ACP v2 preview

The preview allows prompts during active work. The agent can insert or hold
them and chooses how insertion affects active work. The explicit
`delivery: "steer" | "queue"` field and corresponding advertised capabilities
are proposed in RFD #1261. That design grew out of the earlier
`session/inject` discussion and a separate concurrent queueing proposal.
RxCode currently negotiates ACP v1. [ACP v2 prompt lifecycle](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle) · [Prompt delivery RFD #1261](https://github.com/agentclientprotocol/agent-client-protocol/pull/1261) · [Mid-turn input discussion #1220](https://github.com/orgs/agentclientprotocol/discussions/1220) · [Concurrent prompt queueing proposal #484](https://github.com/agentclientprotocol/agent-client-protocol/pull/484)

## Verification

The pre-fix RxCode regression test sent a replacement before the original
`session/prompt` settled. A strict ACP subprocess rejected it as still busy.
The isolated macOS run passed 49 focused tests, including cancellation with a
pending permission request, late output from the old turn, native steer
ordering, idle fallback, missing receipts, legacy versions, queuing during a
steer, and retry after a disconnect. The iOS Simulator build passed.

| Locally probed adapter | Observed behavior |
| --- | --- |
| OpenCode 1.18.3, 1.19.4, 2.2.5 | Initialization omitted the steering extension. OpenCode 1.19.4 cancelled an active streamed turn and accepted a follow-up on the same session with the original instruction still in context. The model ran against a local fixture. |
| Gemini CLI 0.42.0 | Initialization omitted the steering extension. Active-turn cancellation and inference were outside the probe. [Gemini CLI ACP docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md) · [Gemini steering request](https://github.com/google-gemini/gemini-cli/issues/30048) |
| GitHub Copilot CLI 1.0.47 and 1.0.88 | Initialization omitted the steering extension. Active-turn cancellation and inference were outside the probe. [Copilot ACP prompt discussion](https://github.com/github/copilot-cli/issues/4555) |
| Cursor 2026.10.22, Antigravity 1.5.2, legacy Zed Claude Code ACP 0.16.2 | Initialization omitted the steering extension. These were handshake checks. |
| Codex ACP 2.4.0 | Initialization advertised the extension, the idle request returned `promptRequired`, and an injected steer streamed its reply before the original prompt completed against a local model fixture. |
| Claude Agent ACP 0.65.0 | Initialization advertised the extension, the idle request returned `promptRequired`, and an injected steer streamed its reply before the original prompt completed against a local model fixture. |

OpenCode documents one active prompt per session. Claude Agent ACP also offers
its own advertised concurrent prompt queueing, independently of steering.
RxCode’s queue stays local on both. [OpenCode ACP protocol reference](https://github.com/anomalyco/opencode/blob/dev/services/site/src/docs/content/cli/acp.mdx) · [Claude ACP queueing example](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/examples/simple-client.ts)
