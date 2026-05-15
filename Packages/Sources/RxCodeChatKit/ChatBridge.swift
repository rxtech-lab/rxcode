import Foundation
import RxCodeCore

/// Per-window observable bridge between chat views (RxCodeChatKit) and the app-layer services.
///
/// The app target creates one `ChatBridge` per window, sets up action handlers, and keeps the
/// streaming state properties updated. Chat views consume this object via the SwiftUI environment.
@Observable
@MainActor
public final class ChatBridge {

    // MARK: - Streaming State (pushed by AppState)

    public var messages: [ChatMessage] = []
    public var isStreaming: Bool = false
    public var isThinking: Bool = false
    /// True while persisted messages are being loaded from disk for the current session.
    /// MessageListView uses this to keep the ScrollView hidden until messages are present,
    /// preventing the empty → populated "blink" when switching to a session not in memory.
    public var isLoadingFromDisk: Bool = false
    public var streamingStartDate: Date?
    /// Running output-token count for the in-flight turn. Resets on each new stream and
    /// updates as the CLI emits cumulative usage. Surfaced beside the streaming indicator.
    public var liveOutputTokens: Int = 0
    public var lastTurnContextUsedPercentage: Double?
    public var agentProvider: AgentProvider = .claudeCode
    public var modelDisplayName: String = ""
    public var sessionStats: ChatSessionStats = ChatSessionStats()
    public var autoPreviewSettings: AttachmentAutoPreviewSettings = AttachmentAutoPreviewSettings()
    public var appVersion: String = ""
    public var claudeVersion: String?
    public var codexVersion: String?

    /// User decision summaries for `ExitPlanMode` tool calls in the current session,
    /// keyed by `toolCallId`. Pushed by AppState from per-session state and persisted
    /// SwiftData rows. Read by `PlanCardView` and `pendingPlans` so the chip surfaces
    /// the user's decision even after the CLI's own follow-up tool_result has replaced
    /// `ToolCall.result` (which happens on every reload of a CLI-backed session).
    public var planDecisionSummaries: [String: String] = [:]

    // MARK: - Action Handlers (set up by the app target)

    public var sendHandler: (() async -> Void)?
    public var cancelStreamingHandler: (() async -> Void)?
    public var sendSlashCommandHandler: ((String) async -> Void)?
    public var runTerminalCommandHandler: ((String) async -> Void)?
    public var editAndResendHandler: ((UUID, String) async -> Void)?
    public var fetchRateLimitHandler: ((AgentProvider) async -> RateLimitUsage?)?
    public var setSessionProviderHandler: ((AgentProvider) -> Void)?
    public var togglePlanModeHandler: (() async -> Void)?
    public var enqueueMessageHandler: ((String, [Attachment]) -> Void)?
    public var removeQueuedMessageHandler: ((UUID) -> Void)?
    public var dequeueNextForFlushHandler: (() -> QueuedMessage?)?
    public var sendQueuedNowHandler: ((UUID) async -> Void)?
    public var sendAllQueuedAsOneHandler: (() async -> Void)?

    // MARK: - Init

    public init() {}

    // MARK: - Action Methods

    public func send() async {
        await sendHandler?()
    }

    public func cancelStreaming() async {
        await cancelStreamingHandler?()
    }

    public func sendSlashCommand(_ command: String) async {
        await sendSlashCommandHandler?(command)
    }

    public func runTerminalCommand(_ command: String) async {
        await runTerminalCommandHandler?(command)
    }

    public func editAndResend(messageId: UUID, newContent: String) async {
        await editAndResendHandler?(messageId, newContent)
    }

    public func fetchRateLimit() async -> RateLimitUsage? {
        await fetchRateLimitHandler?(agentProvider)
    }

    public func setSessionProvider(_ provider: AgentProvider) {
        setSessionProviderHandler?(provider)
    }

    public func togglePlanMode() async {
        await togglePlanModeHandler?()
    }

    public func enqueueMessage(text: String, attachments: [Attachment]) {
        enqueueMessageHandler?(text, attachments)
    }

    public func removeQueuedMessage(id: UUID) {
        removeQueuedMessageHandler?(id)
    }

    public func dequeueNextForFlush() -> QueuedMessage? {
        dequeueNextForFlushHandler?()
    }

    public func sendQueuedNow(id: UUID) async {
        await sendQueuedNowHandler?(id)
    }

    public func sendAllQueuedAsOne() async {
        await sendAllQueuedAsOneHandler?()
    }

    // MARK: - Plan Decision State

    /// True when the most recent `ExitPlanMode` tool call in the chat is awaiting
    /// a user decision. Drives the input-bar lock so the user cannot send a stray
    /// message while the plan card is still showing Accept/Reject buttons.
    ///
    /// Only the most recent ExitPlanMode matters — older pending cards are
    /// either superseded by a newer decision or no longer the active state.
    public var hasPendingPlanDecision: Bool {
        for messageIdx in messages.indices.reversed() {
            let message = messages[messageIdx]
            for blockIdx in message.blocks.indices.reversed() {
                guard let toolCall = message.blocks[blockIdx].toolCall,
                      PlanCardView.isExitPlanMode(toolCall) else { continue }

                if planDecisionSummaries[toolCall.id] != nil { return false }
                if PlanCardView.isPlanDecided(toolCall) { return false }

                // If anything came after this ExitPlanMode — later blocks in the
                // same message, or any later message — the chat continued past
                // it, so the user must have already acted on the plan. Covers
                // edge cases where neither the persisted decision nor the
                // in-memory result has caught up yet (e.g. mid-reconcile).
                let hasLaterBlock = blockIdx < message.blocks.count - 1
                let hasLaterMessage = messageIdx < messages.count - 1
                if hasLaterBlock || hasLaterMessage { return false }

                return true
            }
        }
        return false
    }

    /// All `ExitPlanMode` tool calls in the current session, mapped to a
    /// presentation-ready `PendingPlan`. Includes both undecided plans (banner
    /// surfaces these) and decided plans (inline chip renders the outcome).
    /// Superseded plans are excluded so a re-emitted plan replaces the prior one.
    public var pendingPlans: [PendingPlan] {
        var collected: [PendingPlan] = []
        for message in messages {
            for block in message.blocks {
                guard let toolCall = block.toolCall,
                      PlanCardView.isExitPlanMode(toolCall) else { continue }
                if PlanCardView.isSupersededExitPlanMode(
                    toolCall: toolCall,
                    in: message,
                    allMessages: messages
                ) { continue }

                let inlineMd = toolCall.input["plan"]?.stringValue ?? ""
                let markdown: String = inlineMd.isEmpty
                    ? (PlanCardView.fallbackPlanMarkdown(in: message)
                        ?? PlanCardView.latestPriorPlanMarkdown(before: message, in: messages)
                        ?? "")
                    : inlineMd

                let persistedSummary = planDecisionSummaries[toolCall.id]
                let decided = persistedSummary != nil || PlanCardView.isPlanDecided(toolCall)
                let summary: String? = persistedSummary
                    ?? (PlanCardView.isPlanDecided(toolCall) ? toolCall.result : nil)
                let isStreaming = message.isStreaming && markdown.isEmpty
                collected.append(PendingPlan(
                    toolCallId: toolCall.id,
                    markdown: markdown,
                    isStreaming: isStreaming,
                    isDecided: decided,
                    decisionSummary: summary
                ))
            }
        }
        return collected
    }
}
