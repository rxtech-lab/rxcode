import Foundation

/// Planning turns begin with a short dispatch for listeners. Host rewrites can
/// annotate individual paragraphs without putting commentary in the approved plan.
nonisolated struct CodingPlanBroadcast {
    let briefing: String?
    let body: String
    private var reasons: [(range: NSRange, text: String)] = []

    init(_ response: String, hostRevision: Bool, streaming: Bool = false) {
        let prefix = "On air: "
        var content = response[...]
        var dispatch: String?
        if content.hasPrefix(prefix) {
            let end = content.firstIndex(where: \.isNewline) ?? content.endIndex
            if end != content.endIndex || !streaming {
                let line = content[..<end].dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { dispatch = String(line.prefix(320)) }
            }
            content = content[end...].drop(while: \.isNewline)
        } else if streaming && prefix.hasPrefix(content) {
            content = content[content.endIndex...]
        }
        briefing = dispatch
        guard hostRevision, content.contains("Edit reason: ") else {
            body = String(content)
            return
        }
        var result = ""
        var offset = 0
        var reason: String?
        var fence: Character?
        for value in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if fence == nil, value.hasPrefix("Edit reason: ") {
                reason = String(value.dropFirst("Edit reason: ".count))
                continue
            }
            if value.hasPrefix("```") || value.hasPrefix("~~~") {
                if fence == value.first { fence = nil } else if fence == nil { fence = value.first }
            }
            if let reason, !value.isEmpty {
                reasons.append((NSRange(location: offset, length: value.utf16.count + 1), reason))
            } else if value.isEmpty { reason = nil }
            result += value
            offset += value.utf16.count
            if value.endIndex < content.endIndex {
                let newline = content[value.endIndex]
                result.append(newline)
                offset += newline.utf16.count
            }
        }
        body = result
    }

    func reason(for edit: CodingPlanReview.Edit) -> String? {
        guard let range = edit.range else { return briefing }
        return reasons.first {
            NSLocationInRange(range.location, $0.range) || NSIntersectionRange(range, $0.range).length > 0
        }?.text ?? briefing
    }
}

nonisolated extension CodingPlan.Step {
    var isHostRevision: Bool {
        switch self {
        case .reconcile, .revise: true
        default: false
        }
    }
}

nonisolated extension CodingPlan.Contribution {
    var radioSummary: String {
        if let briefing { return briefing }
        var source = text
        if isReview {
            let review = CodingPlanReview(text)
            source = review.edits.first?.comment ?? review.commentary
        }
        let prose = SpokenTextChunker.sanitizeForSpeech(CodingPlanReview.feedbackMarkdown(source))
        guard !prose.isEmpty else { return versionID == nil ? "Discussion updated." : "Plan updated." }
        let excerpt = String(prose.prefix(220))
        if let end = excerpt.firstMatch(of: #/[.!?](?:\s|$)/#)?.range {
            return String(excerpt[...end.lowerBound])
        }
        if prose.count > excerpt.count, let space = excerpt.lastIndex(of: " ") {
            return String(excerpt[..<space]) + "…"
        }
        return excerpt
    }
}
