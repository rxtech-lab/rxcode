import Foundation
import RxCodeCore

/// Encapsulates all independent state per session.
/// Stored in the `AppState.sessionStates` dictionary keyed by session ID.
struct SessionStreamState {

    // Messages
    var messages: [ChatMessage] = []

    /// Full `Attachment` objects (including image data, text content, etc.)
    /// for the most recent user turn. `ChatMessage.attachmentPaths` is lossy —
    /// it only stores name/path/type, so we keep the originals here so
    /// `cancelStreaming` can restore them into the input bar alongside the
    /// rolled-back user text.
    var inFlightUserAttachments: [Attachment] = []

    /// True while persisted messages are being loaded from disk into this session.
    /// MessageListView keeps the ScrollView hidden while this is true to avoid the
    /// empty → populated "blink" when switching to a session that isn't already in memory.
    var isLoadingFromDisk = false

    // Streaming
    var isStreaming = false
    var isThinking = false
    var needsNewMessage = false // After receiving .user(tool result), the next block starts a new ChatMessage
    var activeStreamId: UUID?
    /// Bound to the stream that negotiated experimental ACP steering.
    var acpSteeringStreamId: UUID?
    /// A queued send owns its messages until the wire acknowledges the action.
    var queueDispatchInProgress = false
    var queueFlushDeferred = false
    /// Retained after streaming stops so a late save cannot settle a newer turn.
    var latestTurnID: UUID?
    /// Invalidated by a stop or newer turn while the completed transcript is saving.
    var todoContinuationSource: UUID?
    var todoContinuation = TodoContinuation()
    var checkpointRevision = 0
    var checkpointTask: Task<Void, Never>?
    var streamingStartDate: Date?
    var streamTask: Task<Void, Never>?
    var hasUncheckedCompletion = false
    var computerUseWindows: [ComputerUseMonitorWindow] = []

    /// Live background-task ids ("backend agents": background shells, subagents)
    /// this session has spawned that have not yet reported completion. Recent
    /// Claude Code ends the spawning turn with a `result` while these keep
    /// running, then autonomously runs a follow-up turn when they finish. While
    /// this set is non-empty we keep the CLI process alive and the UI "in
    /// progress" instead of tearing the turn down on that yield `result`.
    var liveBackgroundTaskIds: Set<String> = []

    /// Steers delivered to the running Claude turn that the CLI has not yet
    /// echoed back (`--replay-user-messages`). A steer that arrives after the
    /// turn's last tool call is run by the CLI as a turn of its own after this
    /// one's `result`, so while this is non-zero that `result` only yields and
    /// the process is kept alive for the steered turn.
    var unconsumedSteerCount = 0

    /// Last time any stream event (system / assistant / tool result / etc.) arrived
    /// for the active stream. Updated in `processStream` and polled by the
    /// inactivity watchdog so a CLI that goes silent without exiting (broken pipe
    /// not surfaced, MCP child wedged, etc.) gets force-cleaned instead of
    /// leaving `isStreaming`/`activeStreamId` stuck — which would block every
    /// subsequent send into the thread.
    var lastStreamEventDate: Date?

    // Text delta buffer (10-token grouped flush)
    var textDeltaBuffer = ""
    var pendingToolResults: [(toolUseId: String, content: String, isError: Bool)] = []
    var flushTask: Task<Void, Never>?

    // tool_use input streaming buffer
    var activeToolId: String? // tool_use id currently receiving input_json_delta
    var activeToolInputBuffer: String = "" // accumulator for input_json_delta

    // Per-session overrides (persisted in memory across session switches)
    var agentProvider: AgentProvider?
    var model: String?
    /// Per-provider native resume ids for this session, keyed by
    /// `AgentProvider.rawValue`. Mirrors `ChatThread.providerSessionIds`; seeded
    /// on session load and refreshed as each backend reports its native session
    /// id. Lets a switched provider resume its own session (or start fresh)
    /// instead of resuming another provider's id.
    var providerSessionIds: [String: String] = [:]
    /// Identifies which `ACPClientSpec` to use when `agentProvider == .acp`.
    var acpClientId: String?
    var effort: String?
    /// Distinguishes a session using Default from a session awaiting saved metadata.
    private var hasExplicitEffort = false
    var permissionMode: PermissionMode?
    /// Per-session plan-mode toggle. When true, the CLI is launched with `--permission-mode plan`
    /// regardless of the user-selected permission mode. Cleared on session switch.
    var planMode: Bool = false
    /// User decisions for `ExitPlanMode` tool calls, keyed by `toolCallId`. Sidecar
    /// to `ToolCall.result` so the decision survives CLI-backed session reloads —
    /// the CLI emits its own follow-up tool_result ("User has approved your plan…")
    /// that we cannot prevent from overwriting `ToolCall.result` when the session
    /// jsonl is parsed fresh from disk. Loaded from `ThreadStore` on session
    /// activation, written through on every decision.
    var planDecisionSummaries: [String: String] = [:]
    /// Override cwd for this session: when set, CLI runs in this Git worktree path
    /// instead of `project.path`. Persisted on `ChatSession.worktreePath`.
    var worktreePath: String?
    var worktreeBranch: String?

    // Session statistics
    var costUsd: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var durationMs: Double = 0
    var turns: Int = 0
    /// Per-message output-token totals for the in-flight turn, keyed by the assistant
    /// message id. A single turn can contain several model invocations (one per tool-result
    /// round-trip), each emitting its own `usage.output_tokens` from zero — so we track
    /// per-id maxes and sum them to get the running turn total. Reset at stream start.
    var currentTurnOutputTokensByMessage: [String: Int] = [:]
    /// Fallback counter for assistant events that arrive without an `id` (defensive —
    /// the CLI normally always populates it). Reset alongside the map.
    var currentTurnOutputTokensUnkeyed: Int = 0
    /// Sum of all per-message running totals — what the streaming indicator displays.
    var currentTurnOutputTokens: Int {
        currentTurnOutputTokensByMessage.values.reduce(0, +) + currentTurnOutputTokensUnkeyed
    }

    var lastTurnContextUsedPercentage: Double?
    var activeModelName: String?

    /// Set once the LLM title-generation task has been spawned for this session.
    /// Prevents the early (first-text-delta) trigger and the `.result` fallback
    /// from kicking off duplicate generations on the same session.
    var titleGenerationTriggered: Bool = false

    /// Effective workspace directory (`cwd`) of the currently running stream.
    var activeStreamCwd: String?

    /// File-content snapshots captured the first time this session's stream
    /// sees an Edit/MultiEdit/Write tool_use for a given path. Read
    /// synchronously at capture time (content_block_stop / assistant tool_use
    /// arrival) so we read the pre-edit state before the CLI executes the
    /// tool — large files used to lose the race when the read was async and
    /// `originalContent` would end up matching `modifiedContent`. Absence of a
    /// key means the path hasn't been touched yet in this session; the value
    /// can still be `nil` when the read failed (e.g. file does not exist for
    /// a new-file Write).
    var editingFileSnapshots: [String: String?] = [:]

    /// Immediate pre-step file content captured on every structured edit so
    /// concurrent edits on the same file by another thread can be detected.
    var latestStepSnapshots: [String: String?] = [:]

    mutating func setEffort(_ effort: String?) {
        self.effort = effort
        hasExplicitEffort = true
    }

    func effort(fallingBackTo savedEffort: String?) -> String? {
        hasExplicitEffort ? effort : (effort ?? savedEffort)
    }
}
