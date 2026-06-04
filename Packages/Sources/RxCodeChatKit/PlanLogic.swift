import Foundation
import RxCodeCore

/// Plan-mode tool-call helpers extracted from `PlanCardView` so they can be
/// shared between the macOS chat UI (which actually renders the card) and
/// cross-platform consumers like `ChatBridge` and the iOS app.
public enum PlanLogic {
    public static let userDecisionPrefixes: [String] = PlanDecisionAction.userDecisionResultPrefixes

    public static func isPlanDecided(_ toolCall: ToolCall) -> Bool {
        guard let result = toolCall.result else { return false }
        return PlanDecisionAction.isUserDecisionResult(result)
    }

    public static func planMarkdown(from toolCall: ToolCall) -> String? {
        if isExitPlanMode(toolCall) {
            return toolCall.input["plan"]?.stringValue
        }
        if isPlanFileWrite(toolCall) {
            return toolCall.input["content"]?.stringValue
        }
        return nil
    }

    public static func isExitPlanMode(_ toolCall: ToolCall) -> Bool {
        let n = toolCall.name.lowercased()
        return n == "exitplanmode" || n == "exit_plan_mode"
    }

    public static func isPlanFileWrite(_ toolCall: ToolCall) -> Bool {
        guard toolCall.name.lowercased() == "write",
              let path = toolCall.input["file_path"]?.stringValue else {
            return false
        }
        return isPlanFilePath(path)
    }

    /// True when `path` points at a Claude plan markdown file living under a
    /// `.../.claude/plans/` (or `.../claude/plans/`) directory. These plan
    /// documents are planning scaffolding, not real project edits, so the
    /// thread changes list excludes them.
    public static func isPlanFilePath(_ path: String) -> Bool {
        guard path.hasSuffix(".md") else { return false }
        return path.contains("/.claude/plans/") || path.contains("/claude/plans/")
    }

    public static func isPlanReadyFollowup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Plan is ready at ") else { return false }
        return trimmed.contains(".md")
    }

    public static func containsExitPlanMode(_ message: ChatMessage) -> Bool {
        message.blocks.contains { block in
            guard let toolCall = block.toolCall else { return false }
            return isExitPlanMode(toolCall)
        }
    }

    public static func fallbackPlanMarkdown(in message: ChatMessage) -> String? {
        let markdowns: [String] = message.blocks.compactMap { block -> String? in
            guard let toolCall = block.toolCall, isPlanFileWrite(toolCall) else { return nil }
            return planMarkdown(from: toolCall)
        }
        return markdowns.last
    }

    public static func latestPriorPlanMarkdown(before message: ChatMessage, in messages: [ChatMessage]) -> String? {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        for prior in messages[..<idx].reversed() {
            if let md = fallbackPlanMarkdown(in: prior), !md.isEmpty {
                return md
            }
        }
        return nil
    }

    public static func containsPlanFileWrite(_ message: ChatMessage) -> Bool {
        message.blocks.contains { block in
            guard let toolCall = block.toolCall else { return false }
            return isPlanFileWrite(toolCall)
        }
    }

    public static func isPurePlanFileWriteMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant,
              !message.isError,
              !message.isCompactBoundary,
              !message.isStreaming,
              !message.blocks.isEmpty else {
            return false
        }
        return message.blocks.allSatisfy { block in
            guard let toolCall = block.toolCall else { return false }
            return isPlanFileWrite(toolCall)
        }
    }

    public static func renderMarkdown(for toolCall: ToolCall, in message: ChatMessage) -> String? {
        if isExitPlanMode(toolCall) {
            let markdown = toolCall.input["plan"]?.stringValue ?? ""
            return markdown.isEmpty ? (fallbackPlanMarkdown(in: message) ?? markdown) : markdown
        }
        return planMarkdown(from: toolCall)
    }

    public static func shouldHideBlock(
        _ block: MessageBlock,
        in message: ChatMessage,
        allMessages: [ChatMessage] = []
    ) -> Bool {
        let hasExitPlanInMessage = containsExitPlanMode(message)
        if block.text != nil { return false }
        guard let toolCall = block.toolCall, isPlanFileWrite(toolCall) else { return false }
        return hasExitPlanInMessage || assistantRunContainsExitPlanMode(after: message, in: allMessages)
    }

    private static func assistantRunContainsExitPlanMode(
        after message: ChatMessage,
        in allMessages: [ChatMessage]
    ) -> Bool {
        guard let idx = allMessages.firstIndex(where: { $0.id == message.id }) else { return false }
        for i in (idx + 1)..<allMessages.count {
            let m = allMessages[i]
            if m.role == .user { break }
            if containsExitPlanMode(m) { return true }
        }
        if idx > 0 {
            for i in stride(from: idx - 1, through: 0, by: -1) {
                let m = allMessages[i]
                if m.role == .user { break }
                if containsExitPlanMode(m) { return true }
            }
        }
        return false
    }

    public static func isSupersededExitPlanMode(
        toolCall: ToolCall,
        in message: ChatMessage,
        allMessages: [ChatMessage]
    ) -> Bool {
        guard isExitPlanMode(toolCall) else { return false }
        guard let msgIdx = allMessages.firstIndex(where: { $0.id == message.id }) else { return false }
        var sawSelf = false
        for i in msgIdx..<allMessages.count {
            let m = allMessages[i]
            if i > msgIdx, m.role == .user { return false }
            for block in m.blocks {
                guard let tc = block.toolCall, isExitPlanMode(tc) else { continue }
                if tc.id == toolCall.id { sawSelf = true; continue }
                if sawSelf { return true }
            }
        }
        return false
    }
}
