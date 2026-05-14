import Foundation
import ClarcCore

/// Per-window observable bridge between chat views (ClarcChatKit) and the app-layer services.
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
    public var modelDisplayName: String = ""
    public var sessionStats: ChatSessionStats = ChatSessionStats()
    public var autoPreviewSettings: AttachmentAutoPreviewSettings = AttachmentAutoPreviewSettings()
    public var appVersion: String = ""
    public var claudeVersion: String?

    // MARK: - Action Handlers (set up by the app target)

    public var sendHandler: (() async -> Void)?
    public var cancelStreamingHandler: (() async -> Void)?
    public var sendSlashCommandHandler: ((String) async -> Void)?
    public var runTerminalCommandHandler: ((String) async -> Void)?
    public var editAndResendHandler: ((UUID, String) async -> Void)?
    public var fetchRateLimitHandler: (() async -> RateLimitUsage?)?
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
        await fetchRateLimitHandler?()
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
        for message in messages.reversed() {
            for block in message.blocks.reversed() {
                guard let toolCall = block.toolCall,
                      PlanCardView.isExitPlanMode(toolCall) else { continue }
                return !PlanCardView.isPlanDecided(toolCall)
            }
        }
        return false
    }
}
