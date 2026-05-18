import Foundation
import SwiftUI

// MARK: - InspectorTab

public enum InspectorTab: String, CaseIterable {
    case memo = "Memo"
    case terminal = "Terminal"
    case run = "Run"

    public var icon: String {
        switch self {
        case .terminal: "apple.terminal"
        case .memo: "note.text"
        case .run: "play.fill"
        }
    }
}

// MARK: - InspectorReviewTab

public enum InspectorReviewTab: String, CaseIterable, Sendable {
    case thisThread = "This thread"
    case unstaged = "Unstaged"
    case staged = "Staged"
    case branch = "Branch"
}

// MARK: - InspectorMode

public enum InspectorMode: String, CaseIterable, Sendable {
    case review = "Review"
    case inspector = "Inspector"
}

// MARK: - QueuedMessage

public struct QueuedMessage: Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var attachments: [Attachment]

    public init(id: UUID = UUID(), text: String, attachments: [Attachment]) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}

/// Per-window independent UI/session state. Does not own services or shared data.
@Observable
@MainActor
public final class WindowState {

    // MARK: - Window Identity

    public let id = UUID()
    public var newSessionKey: String { "__new_\(id.uuidString)__" }

    // MARK: - Project / Session Selection

    public var selectedProject: Project?
    public var currentSessionId: String?

    // MARK: - Placeholder Tracking

    public private(set) var pendingPlaceholderIds: Set<String> = []

    // MARK: - Input

    public var inputText = ""
    public var attachments: [Attachment] = []
    public var draftTexts: [String: String] = [:]
    public var draftQueues: [String: [QueuedMessage]] = [:]

    // MARK: - Message Queue

    public var messageQueue: [QueuedMessage] = []

    public func enqueueMessage(text: String, attachments: [Attachment]) {
        messageQueue.append(QueuedMessage(text: text, attachments: attachments))
    }

    public func dequeueMessage(id: UUID) {
        messageQueue.removeAll { $0.id == id }
    }

    public func dequeueNext() -> QueuedMessage? {
        guard !messageQueue.isEmpty else { return nil }
        return messageQueue.removeFirst()
    }

    // MARK: - Permission Queue

    public var pendingPermissions: [PermissionRequest] = []
    /// The pending permission whose detail modal is currently presented. Nil means
    /// only the queued-permission banner is showing (or the queue is empty). Set by
    /// the banner's tap action, cleared by the modal's close button / Esc / decision.
    public var presentedPermissionId: String?

    // MARK: - AskUserQuestion Response Handler

    /// Invoked by the question sheet when the user submits answers for an
    /// `AskUserQuestion` tool prompt. Parameters: (toolUseId, answersByQuestionIndex).
    /// Set by `AppState` at window init.
    public var submitQuestionAnswersHandler: (@MainActor @Sendable (String, [Int: AskUserQuestion.Answer]) -> Void)?

    /// Invoked by the question sheet when the user dismisses without answering.
    /// Resolves the underlying PreToolUse hook as `deny`. Parameter: toolUseId.
    public var skipQuestionHandler: (@MainActor @Sendable (String) -> Void)?

    // MARK: - Plan Decision Handler

    /// Invoked by the plan sheet when the user picks Accept / Accept-with-edits /
    /// Accept / reject decisions. Set by `AppState` at window init.
    public var planDecisionHandler: (@MainActor @Sendable (String, PlanDecisionAction) -> Void)?

    /// `ToolCall.id` of the plan whose sheet is currently presented. Nil means the
    /// sheet is closed (banner / inline chip may still be visible). Set by the
    /// banner's tap action and the inline chip; cleared by the sheet's close
    /// button / Esc / outside-tap. Closing the sheet is NOT a decline — the plan
    /// remains pending until a decision is recorded via `planDecisionHandler`.
    public var presentedPlanToolCallId: String?

    // MARK: - UI State

    public var interactiveTerminal: InteractiveTerminalState?
    public var showInspector: Bool = false
    public var inspectorMode: InspectorMode = .review
    public var inspectorTab: InspectorTab = .memo
    /// Currently-selected run profile in the toolbar picker. Persisted only in
    /// memory — re-selecting on relaunch is fine. Per-window so two windows
    /// can target different profiles in the same project.
    public var selectedRunProfileId: UUID?
    /// Whether the run-configurations editor sheet is open.
    public var showRunConfigurations: Bool = false
    /// Which active run task the Run inspector tab is currently displaying.
    public var selectedRunTaskId: UUID?
    public var inspectorReviewTab: InspectorReviewTab = .thisThread
    public var inspectorFile: PreviewFile?
    public var diffFile: PreviewFile?
    public var showingBriefing = true
    public var showMarketplace = false
    /// Whether the global thread-search overlay is presented. Toggled by the
    /// toolbar magnifier button and the Cmd+K shortcut.
    public var showGlobalSearch = false
    public var showModelPicker = false
    public var showEffortPicker = false
    /// Per-session model override. When set, this model is used instead of the global default.
    /// Cleared when a new chat is started or a different session is selected.
    public var sessionModel: String?
    /// Per-session agent provider override. Kept with `sessionModel` so new
    /// sessions and resumes route to the correct runtime.
    public var sessionAgentProvider: AgentProvider?
    /// Per-session effort override. When set, passed as --effort to the CLI.
    /// Cleared when a new chat is started or a different session is selected.
    public var sessionEffort: String?
    /// Per-session permission mode override. When set, overrides the global permissionMode.
    /// Cleared when a new chat is started or a different session is selected.
    public var sessionPermissionMode: PermissionMode?
    /// Per-session plan-mode toggle. Orthogonal to `sessionPermissionMode` — when true,
    /// the CLI is launched with `--permission-mode plan` regardless of the dropdown selection.
    /// Toggled by Shift+Tab and the Plan pill in the input bar.
    public var sessionPlanMode: Bool = false
    public var requestInputFocus = false
    public var isInitialized = false
    public var errorMessage: String?
    public var showError = false

    // MARK: - Window Kind

    public var isProjectWindow = false

    // MARK: - Focus Mode

    public var focusMode: Bool = false

    // MARK: - Session Switch Task

    private var sessionSwitchTask: Task<Void, Never>?

    public init() {}

    // MARK: - Internal Helpers

    public func insertPendingPlaceholder(_ id: String) {
        pendingPlaceholderIds.insert(id)
    }

    public func removePendingPlaceholder(_ id: String) {
        pendingPlaceholderIds.remove(id)
    }

    public func cancelSessionSwitchTask() {
        sessionSwitchTask?.cancel()
    }

    public func setSessionSwitchTask(_ task: Task<Void, Never>) {
        sessionSwitchTask = task
    }

    // MARK: - Attachment Helpers

    public func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
        if attachment.type == .image {
            insertImageToken(for: attachment)
        }
    }

    public func removeAttachment(_ id: UUID) {
        if let idx = attachments.firstIndex(where: { $0.id == id }) {
            let removed = attachments.remove(at: idx)
            if removed.type == .image {
                removeImageToken(for: removed)
                renumberImageTokens()
            }
        }
    }

    /// Numeric index of an image attachment (1-based) in display order.
    public func imageIndex(for id: UUID) -> Int? {
        let imageOnly = attachments.filter { $0.type == .image }
        guard let i = imageOnly.firstIndex(where: { $0.id == id }) else { return nil }
        return i + 1
    }

    public func imageDisplayToken(for id: UUID) -> String? {
        guard let idx = imageIndex(for: id) else { return nil }
        return "[Image\(idx)]"
    }

    private func insertImageToken(for attachment: Attachment) {
        guard let token = imageDisplayToken(for: attachment.id) else { return }
        if inputText.isEmpty {
            inputText = token + " "
        } else if inputText.hasSuffix(" ") || inputText.hasSuffix("\n") {
            inputText.append(token + " ")
        } else {
            inputText.append(" \(token) ")
        }
    }

    private func removeImageToken(for attachment: Attachment) {
        guard let token = imageDisplayToken(for: attachment.id) else { return }
        // Strip the token plus an optional adjacent space.
        let patterns = [token + " ", " " + token, token]
        var text = inputText
        for p in patterns {
            if let range = text.range(of: p) {
                text.removeSubrange(range)
                break
            }
        }
        inputText = text
    }

    /// After removing an image, renumber the remaining `[ImageN]` tokens.
    private func renumberImageTokens() {
        var text = inputText
        let images = attachments.filter { $0.type == .image }
        // First replace existing tokens with placeholders to avoid collision (e.g. [Image10] vs [Image1]).
        // Match any [Image<digits>] and substitute by a stable placeholder.
        var counter = 1
        var output = ""
        var remaining = Substring(text)
        while let r = remaining.range(of: #"\[Image\d+\]"#, options: .regularExpression) {
            output += remaining[..<r.lowerBound]
            if counter <= images.count {
                output += "[Image\(counter)]"
                counter += 1
            }
            remaining = remaining[r.upperBound...]
        }
        output += remaining
        text = output
        inputText = text
    }
}
