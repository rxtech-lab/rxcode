import Foundation
import RxAgentCore
import RxCodeCore

/// Translates the SDK's normalized `AgentEvent` stream into the `StreamEvent`
/// stream `AppState` already consumes.
///
/// Mostly one-to-one, with three places where it has to remember something:
///
///   * `sessionID` — RxCode's `ResultEvent` carries the session id, but the SDK
///     reports it once at `sessionStarted` and again (optionally) at
///     `turnEnded`. The bridge holds onto the first one it sees.
///   * `contextWindow` — the SDK reports it as its own event whenever it
///     changes; RxCode only reads it off the terminal `ResultEvent`. So the
///     latest value is held and attached at the end.
///   * `usage` — same shape of problem, and additionally RxCode's `UsageInfo`
///     has no cost field while the SDK's does, so the cost is carried
///     separately into `ResultEvent.totalCostUsd`.
///
/// Not a `Sendable` value type: one instance belongs to one turn, and is only
/// ever touched from the actor draining that turn's stream.
final class AgentEventBridge {
    /// ACP agents report their model list mid-stream. RxCode routes that back
    /// into the matching `ACPClientSpec`, which is keyed by the client's id —
    /// so a bridge for a non-ACP client has nothing to attribute the list to
    /// and drops it.
    private let acpClientID: String?
    private let startedAt = Date()

    private var sessionID: String?
    private var contextWindow: RxAgentCore.ContextWindowInfo?
    private var latestUsage: RxAgentCore.UsageInfo?

    init(acpClientID: String? = nil) {
        self.acpClientID = acpClientID
    }

    /// The session id the agent reported, once it has reported one. The backend
    /// reads this after the stream ends to persist the resume point.
    var nativeSessionID: String? { sessionID }

    /// Map one SDK event onto zero or more `StreamEvent`s.
    ///
    /// Zero is the common case for the SDK's structural events —
    /// `messageStarted`, `blockStarted`, `blockEnded` — which exist so a
    /// transcript reducer can be written as a pure function. RxCode's state
    /// machine infers the same structure from the deltas themselves, so
    /// forwarding them would be noise.
    func translate(_ event: AgentEvent) -> [StreamEvent] {
        switch event {
        case .sessionStarted(let started):
            sessionID = started.nativeSessionID
            return [.system(SystemEvent(
                subtype: "init",
                sessionId: started.nativeSessionID,
                tools: started.advertisedTools.isEmpty ? nil : started.advertisedTools,
                model: started.model,
                claudeCodeVersion: nil
            ))]

        case .textDelta(let text):
            return [.textDelta(text)]

        case .thinkingDelta(let text):
            return [.thinkingDelta(text)]

        case .toolCallStarted(let id, let name):
            return [.toolCallStarted(id: id, name: name)]

        case .toolCallInput(let id, let input):
            return [.toolCallInput(id: id, input: input.mapValues(AppJSON.init))]

        case .toolCallResult(let id, let content, let isError):
            return [.user(UserMessage(toolUseId: id, content: content, isError: isError))]

        case .messageEnded(let id, let usage):
            guard let usage else { return [] }
            latestUsage = usage
            // Delivered as an `.assistant` with no content because that is the
            // event RxCode meters per-message output tokens from; the blocks
            // themselves already arrived as deltas.
            return [.assistant(AssistantMessage(
                id: id,
                role: "assistant",
                content: [],
                usage: RxCodeCore.UsageInfo(usage)
            ))]

        case .usage(let usage):
            latestUsage = usage
            return [.assistant(AssistantMessage(
                id: nil,
                role: "assistant",
                content: [],
                usage: RxCodeCore.UsageInfo(usage)
            ))]

        case .contextWindow(let window):
            contextWindow = window
            return []

        case .todos(let items):
            return [.todoSnapshot(TodoSnapshotEvent(
                sessionId: sessionID,
                items: items.map(RxCodeCore.TodoItem.init)
            ))]

        case .rateLimit(let info):
            return [.rateLimitEvent(RxCodeCore.RateLimitInfo(
                status: info.message,
                // RxCode's UI counts down; the SDK reports the wall-clock time
                // the limit lifts. A reset already in the past means "retry
                // now", which reads better as no countdown than as a negative.
                retrySec: info.resetsAt.map { max(0, $0.timeIntervalSinceNow) }
            ))]

        case .modelsDiscovered(let models):
            guard let acpClientID, !models.isEmpty else { return [] }
            return [.acpModelsDiscovered(ACPModelsDiscoveredEvent(
                clientId: acpClientID,
                config: ACPModelConfig(
                    configId: Self.discoveredModelConfigID,
                    options: models.map {
                        ACPModelOption(
                            value: $0.id,
                            name: $0.displayName,
                            description: $0.modelDescription
                        )
                    }
                )
            ))]

        case .backgroundTask(let task):
            return [.system(SystemEvent(
                subtype: Self.systemSubtype(for: task.status),
                sessionId: sessionID,
                tools: nil,
                model: nil,
                claudeCodeVersion: nil,
                taskId: task.taskID,
                taskStatus: task.status == .started ? nil : task.status.rawValue
            ))]

        case .turnEnded(let result):
            if let usage = result.usage { latestUsage = usage }
            if let native = result.nativeSessionID { sessionID = native }
            return [.result(makeResult(isError: result.isError, durationMS: result.durationMS,
                                       isBackgroundFollowUp: result.isBackgroundFollowUp))]

        case .failed(let error):
            // `.cancelled` is the user pressing stop. The UI has already moved
            // on, and an error bubble for a deliberate interruption is noise —
            // but the turn still has to be closed out, so it ends as a
            // non-error result.
            let isError = error != .cancelled
            return [.result(makeResult(isError: isError, durationMS: nil, isBackgroundFollowUp: false))]

        // Structural and diagnostic events with no RxCode equivalent.
        case .turnStarted, .messageStarted, .blockStarted, .blockEnded, .diagnostic:
            return []

        // Approvals are answered through the injected `PermissionResolving`,
        // which already drives the same UI. Forwarding the event too would
        // raise the sheet twice for one call.
        case .permissionRequested:
            return []
        }
    }

    /// Text for the error bubble when a turn fails. `AppState` renders the
    /// backend's stderr, and an SDK client's failure detail is the closest
    /// equivalent it has.
    static func failureDetail(_ event: AgentEvent) -> String? {
        guard case .failed(let error) = event, error != .cancelled else { return nil }
        return error.description
    }

    // MARK: - Private

    private func makeResult(isError: Bool, durationMS: Int?, isBackgroundFollowUp: Bool) -> ResultEvent {
        ResultEvent(
            durationMs: durationMS.map(Double.init)
                ?? Date().timeIntervalSince(startedAt) * 1000,
            totalCostUsd: latestUsage?.totalCostUSD,
            sessionId: sessionID ?? "",
            isError: isError,
            totalTurns: nil,
            usage: latestUsage.map(RxCodeCore.UsageInfo.init),
            contextWindow: contextWindow.map(RxCodeCore.ContextWindowInfo.init),
            originKind: isBackgroundFollowUp ? "task-notification" : nil
        )
    }

    /// `ACPModelConfig.configId` identifies the selector to write back to with
    /// `session/set_config_option`. The SDK's `modelsDiscovered` doesn't carry
    /// one, so discovered lists are tagged with a fixed id — enough for the
    /// picker to render, not enough to switch models live. Wiring that back up
    /// needs the id plumbed through `AgentEvent`.
    private static let discoveredModelConfigID = "model"

    private static func systemSubtype(for status: BackgroundTaskEvent.Status) -> String {
        switch status {
        case .started: "task_started"
        case .updated: "task_updated"
        case .completed, .failed: "task_notification"
        }
    }
}

// MARK: - Usage / context window

private extension RxCodeCore.UsageInfo {
    init(_ usage: RxAgentCore.UsageInfo) {
        self.init(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationInputTokens: usage.cacheCreationTokens,
            cacheReadInputTokens: usage.cacheReadTokens
        )
    }
}

private extension RxCodeCore.ContextWindowInfo {
    init(_ window: RxAgentCore.ContextWindowInfo) {
        let used = window.fractionUsed * 100
        self.init(usedPercentage: used, remainingPercentage: 100 - used)
    }
}
