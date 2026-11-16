import Foundation
import RxCodeCore

extension AppState {
    /// Drop "No response requested." text blocks from the assistant message
    /// at `idx`. The marker is the model's response when a turn arrives
    /// without a user prompt (ScheduleWakeup, hook re-entry) and reads as
    /// noise in the chat UI.
    ///
    /// `removeIfEmpty` controls whether a message left with no blocks is also
    /// deleted. The normal stream path passes `true` to discard pure no-op
    /// envelopes; the cancel path passes `false` so pausing a turn never makes
    /// the partial assistant bubble disappear.
    static func stripNoOpText(at idx: Int, in messages: inout [ChatMessage], removeIfEmpty: Bool = true) {
        guard messages.indices.contains(idx) else { return }
        messages[idx].blocks.removeAll { block in
            guard let text = block.text else { return false }
            return CLIMetaEnvelope.isNoResponseRequested(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if removeIfEmpty, messages[idx].blocks.isEmpty {
            messages.remove(at: idx)
        }
    }

    /// Preview up to two briefings per day so a busy day cannot crowd out the others.
    func projectBriefingSystemPrompt(
        projectId: UUID, canFetchDetails: Bool, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        guard projectId != Project.globalChatID else { return "" }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -2, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return "" }

        let items = threadStore.recentProjectBriefingItems(projectId: projectId, startingAt: start, before: end)
        var entries: [String] = []
        var entriesByDay: [String: Int] = [:]
        for item in items {
            guard let day = item.day else { continue }
            let date = BranchBriefingRecord.dayKey(day, calendar: calendar)
            guard entriesByDay[date, default: 0] < 2 else { continue }
            let briefing = item.briefing.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("### ") }
                .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
                .joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !briefing.isEmpty else { continue }
            let detail = "\(item.branch): \(briefing)"
            let preview = detail.count > 175 ? String(detail.prefix(174)) + "…" : detail
            entries.append("- \(date) \(preview)")
            entriesByDay[date, default: 0] += 1
        }
        guard !entries.isEmpty else { return "" }

        var lines = ["# Recent project briefings", "Background only. The current request takes priority."]
        if canFetchDetails {
            lines.append("Use ide__project_briefings and ide__project_briefing_get for full or older briefings.")
        }
        return (lines + entries).joined(separator: "\n")
    }

    static func promptWithBackgroundContext(_ contexts: [String], prompt: String) -> String {
        let context = contexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !context.isEmpty else { return prompt }
        return """
        \(context)

        User request:
        \(prompt)
        """
    }

    static func configuredPromptContext(global: String?, project: String?) -> String {
        let global = global?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            global.isEmpty ? nil : "# Global instructions\n\n\(global)",
            project.isEmpty ? nil : "# Project instructions\n\n\(project)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    nonisolated static func streamEventLogName(_ event: StreamEvent) -> String {
        switch event {
        case .system(let systemEvent):
            return "system.\(systemEvent.subtype)"
        case .assistant:
            return "assistant"
        case .user:
            return "user"
        case .result:
            return "result"
        case .rateLimitEvent:
            return "rateLimitEvent"
        case .todoSnapshot:
            return "todoSnapshot"
        case .acpModelsDiscovered:
            return "acpModelsDiscovered"
        case .textDelta:
            return "textDelta"
        case .thinkingDelta:
            return "thinkingDelta"
        case .toolCallStarted:
            return "toolCallStarted"
        case .toolCallInput:
            return "toolCallInput"
        case .unknown:
            return "unknown"
        }
    }
}
