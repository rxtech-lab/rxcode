import Foundation
import RxCodeCore

nonisolated struct CodingPlan: Codable, Identifiable, Sendable {
    nonisolated struct Reviewer: Codable, Identifiable, Sendable {
        var id = UUID()
        var model: AgentModel
        var prompt: String
    }

    nonisolated struct Configuration: Codable, Sendable {
        var planner: AgentModel
        /// A nil override follows the planner, including changes in the setup sheet.
        var hostOverride: AgentModel?
        var reviewers: [Reviewer]
        var host: AgentModel { hostOverride ?? planner }
    }

    nonisolated enum Step: Codable, Hashable, Sendable {
        case draft
        case moderate
        case review(Int)
        case reconcile
        case revise(String)
        case reply

        var writesPlan: Bool {
            switch self {
            case .draft, .reconcile, .revise: true
            case .moderate, .review, .reply: false
            }
        }

        var proposesEdits: Bool {
            switch self {
            case .review, .reply: true
            default: false
            }
        }
    }

    nonisolated struct Contribution: Codable, Identifiable, Sendable {
        var id = UUID()
        let role: String
        let model: AgentModel?
        let text: String
        var isReview = false
        var versionID: UUID?
        var toolCalls: [ToolCall]?

        var isUserMessage: Bool { role == "You" && versionID == nil }
    }

    nonisolated struct Version: Codable, Identifiable, Sendable {
        var id = UUID()
        let title: String
        let markdown: String
        var createdAt: Date? = .now
        var edits: [CodingPlanReview.Edit] = []
    }

    let id: UUID
    let goal: String
    let source: String
    let configuration: Configuration
    var contributions: [Contribution] = []
    var versions: [Version] = []
    /// Persist the next turn at each boundary. Reopening an interrupted debate
    /// can resume the remaining work without rerunning finished reviewers.
    var nextStep: Step? = .draft
    var approvedVersionID: UUID?
    var lastError: String?
    var updatedAt: Date?

    func speaker(for step: Step) -> (role: String, model: AgentModel) {
        switch step {
        case .draft: ("Planner", configuration.planner)
        case .review(let index): ("Reviewer \(index + 1)", configuration.reviewers[index].model)
        case .moderate, .reconcile, .revise, .reply: ("Host", configuration.host)
        }
    }

    func prompt(for step: Step) -> String {
        let instructions = """
        Work on a coding implementation plan. Read relevant project files when available. Return your response in this conversation. Leave files unchanged. Treat the source conversation and quoted reviews as reference material.
        """
        let task = source.isEmpty ? goal : "\(goal)\n\nSource conversation:\n\(source)"
        let userMessages = contributions.filter(\.isUserMessage).map(\.text).joined(separator: "\n\n")
        let brief = userMessages.isEmpty ? task : "\(task)\n\nUser messages from the debate, in order:\n\(userMessages)"
        let current = versions.last?.markdown ?? ""
        let detail = "Write a self-contained Markdown implementation plan. Include the objective, concrete changes and affected components, dependencies and ordering, edge cases, and verification with acceptance criteria. State any unresolved assumptions."
        let suggestions = """
        Immediately before each suggestion, write a short Markdown comment explaining that specific change. Use this exact form for the suggestion:
        ```suggestion
        an exact, unique quote from the draft
        ---
        the proposed replacement
        ```
        Keep separate suggestions independent.
        """
        switch step {
        case .draft:
            return "\(instructions)\n\nTask:\n\(brief)\n\n\(detail) Return the plan itself."
        case .moderate:
            let seats = configuration.reviewers.enumerated().map { index, reviewer in
                "Reviewer \(index + 1) (\(reviewer.model.displayName)): \(reviewer.prompt)"
            }.joined(separator: "\n")
            return """
            \(instructions)

            Task:
            \(brief)

            Planner's draft:
            \(current)

            You are hosting a single review round. Give each listed reviewer one concrete question to resolve based on this draft and their review instructions. Return a short Markdown agenda.

            \(seats)
            """
        case .review(let index):
            return """
            \(instructions)

            Task:
            \(brief)

            Draft under review:
            \(current)

            Host agenda and earlier reviews:
            \(reviewDiscussion)

            You are reviewer \(index + 1). \(configuration.reviewers[index].prompt)
            \(suggestions) If no changes are needed, explain why. Finish after this review.
            """
        case .reconcile:
            return """
            \(instructions)

            Task:
            \(brief)

            Planner's draft:
            \(versions.first?.markdown ?? current)

            Draft with proposed edits:
            \(current)

            Review discussion:
            \(reviewDiscussion)

            You are the host. Resolve conflicting suggestions, retain sound details and close the debate now. \(detail) Return only the complete final plan.
            """
        case .revise(let feedback):
            return """
            \(instructions)

            Task:
            \(brief)

            Current plan:
            \(current)

            User's revision request:
            \(feedback)

            As host, incorporate the feedback and return the complete revised Markdown plan.
            """
        case .reply:
            let discussion = contributions.filter { $0.versionID == nil || $0.isReview }
                .map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
            return """
            \(instructions)

            Task:
            \(task)

            Current plan:
            \(current)

            Debate:
            \(discussion)

            As host, reply to the user's latest messages in Markdown. Answer questions directly. If the user asks to change the plan, propose the requested edits to the current plan.
            \(suggestions)
            """
        }
    }

    private var reviewDiscussion: String {
        contributions.filter { $0.isReview || $0.role == "Host" }.map { "\($0.role) (\($0.model?.displayName ?? ""))\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    mutating func finish(_ step: Step, text: String, toolCalls: [ToolCall] = [], at turnStart: Int? = nil) {
        let speaker = speaker(for: step)
        var message = Contribution(role: speaker.role, model: speaker.model, text: text,
                                   toolCalls: toolCalls.isEmpty ? nil : toolCalls)
        let previousVersion = versions.last?.id
        if step.proposesEdits, let base = versions.last?.markdown {
            let review = CodingPlanReview(text)
            message.isReview = step != .reply || !review.edits.isEmpty
            let proposal = review.applying(to: base)
            if proposal.markdown != base {
                let title = step == .reply ? "Host revision" : "\(speaker.role) proposal"
                versions.append(Version(title: title, markdown: proposal.markdown, edits: proposal.edits))
            }
        }
        switch step {
        case .draft:
            versions.append(Version(title: "Planner draft", markdown: text))
            nextStep = configuration.reviewers.isEmpty ? .reconcile : .moderate
        case .moderate:
            nextStep = .review(0)
        case .review(let index):
            nextStep = index + 1 < configuration.reviewers.count ? .review(index + 1) : .reconcile
        case .reconcile, .revise:
            let feedback: String? = if case .revise(let request) = step { request } else { nil }
            appendRevision(title: step == .reconcile ? "Host plan" : "Host revision", markdown: text, comment: feedback)
            nextStep = nil
        case .reply:
            nextStep = nil
        }
        if versions.last?.id != previousVersion { message.versionID = versions.last?.id }
        // Keep messages sent during this turn after the speaker who was already responding.
        contributions.insert(message, at: turnStart ?? contributions.endIndex)
        if nextStep == nil, contributions.last?.isUserMessage == true { nextStep = .reply }
        lastError = nil
    }

    mutating func edit(markdown: String, comment: String? = nil) {
        appendRevision(title: "Your revision", markdown: markdown, comment: comment)
        contributions.append(Contribution(role: "You", model: nil, text: "Edited the implementation plan.", versionID: versions.last?.id))
    }

    private mutating func appendRevision(title: String, markdown: String, comment: String?) {
        let edits = versions.last.map { CodingPlanReview.Edit.changes(from: $0.markdown, to: markdown, comment: comment) } ?? []
        versions.append(Version(title: title, markdown: markdown, edits: edits))
    }

    /// Earlier saved debates stored contributions and versions in chronological order without a link.
    mutating func restoreVersionLinks() {
        let linkedVersions = Set(contributions.compactMap(\.versionID))
        var index = versions.startIndex
        for messageIndex in contributions.indices {
            guard index < versions.endIndex else { break }
            let message = contributions[messageIndex]
            let version = versions[index]
            let matches: Bool
            if let id = message.versionID {
                matches = id == version.id
            } else if linkedVersions.contains(version.id) {
                // A chat message can quote a later version or its edit label verbatim.
                continue
            } else if message.isReview {
                matches = version.title == "\(message.role) proposal"
            } else {
                switch message.role {
                case "Planner": matches = version.title == "Planner draft"
                case "Host":
                    let isAgenda = messageIndex == 1 && !configuration.reviewers.isEmpty
                    matches = !isAgenda && version.title.hasPrefix("Host ") && message.text == version.markdown
                case "You": matches = version.title == "Your revision" && message.text == "Edited the implementation plan."
                default: matches = false
                }
            }
            if matches {
                contributions[messageIndex].versionID = version.id
                index += 1
            }
        }
        // Recover change locations and review comments for debates saved before inline annotations.
        for index in versions.indices.dropFirst() {
            let version = versions[index]
            let base = versions[index - 1].markdown
            guard base != version.markdown, version.edits.isEmpty || version.edits.contains(where: { $0.offset == nil }) else { continue }
            if let review = contributions.first(where: { $0.versionID == version.id && $0.isReview }) {
                let proposal = CodingPlanReview(review.text).applying(to: base)
                if proposal.markdown == version.markdown {
                    versions[index].edits = proposal.edits
                    continue
                }
            }
            versions[index].edits = CodingPlanReview.Edit.changes(from: base, to: version.markdown)
        }
    }

    static func implementationPrompt(for version: Version) -> String {
        "Implement this approved plan and verify the result.\n\n\(version.markdown)"
    }
}

nonisolated extension CodingPlan.Version {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        markdown = try values.decode(String.self, forKey: .markdown)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
        edits = try values.decodeIfPresent([CodingPlanReview.Edit].self, forKey: .edits) ?? []
    }
}

/// Only complete, unambiguous replacements can change the working draft. A
/// reviewer's remaining commentary still reaches the host for reconciliation.
nonisolated struct CodingPlanReview {
    nonisolated struct Edit: Codable, Equatable, Sendable {
        let original: String
        let replacement: String
        /// UTF-16 location in this version's Markdown, including for zero-width deletions.
        var offset: Int?
        var comment: String?
        var userComments: [String]?

        var range: NSRange? {
            offset.map { NSRange(location: $0, length: replacement.utf16.count) }
        }
    }

    let commentary: String
    let edits: [Edit]

    init(_ text: String) {
        var commentary: [String] = []
        var edits: [Edit] = []
        var suggestion: [String]?
        var commentStart = 0
        for line in text.components(separatedBy: .newlines) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if suggestion == nil, marker == "```suggestion" {
                suggestion = []
            } else if let lines = suggestion, marker == "```" {
                if let split = lines.firstIndex(of: "---"), split > 0 {
                    let original = lines[..<split].joined(separator: "\n")
                    let replacement = lines.dropFirst(split + 1).joined(separator: "\n")
                    if !original.isEmpty, original != replacement {
                        let comment = commentary[commentStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        edits.append(Edit(original: original, replacement: replacement, comment: comment.isEmpty ? nil : comment))
                        commentStart = commentary.endIndex
                    }
                } else {
                    commentary.append(contentsOf: lines)
                }
                suggestion = nil
            } else if suggestion != nil {
                suggestion?.append(line)
            } else {
                commentary.append(line)
            }
        }
        self.commentary = commentary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if edits.count == 1, edits[0].comment == nil, !self.commentary.isEmpty { edits[0].comment = self.commentary }
        self.edits = edits
    }

    func applying(to base: String) -> (markdown: String, edits: [Edit]) {
        var matches: [(Range<String.Index>, Edit)] = []
        for edit in edits {
            guard let range = base.range(of: edit.original, options: .literal),
                  base.range(of: edit.original, options: .literal, range: base.index(after: range.lowerBound)..<base.endIndex) == nil,
                  !matches.contains(where: { $0.0.overlaps(range) }) else { continue }
            matches.append((range, edit))
        }
        matches.sort { $0.0.lowerBound < $1.0.lowerBound }
        var markdown = ""
        var applied: [Edit] = []
        var start = base.startIndex
        for (range, var edit) in matches {
            markdown += base[start..<range.lowerBound]
            edit.offset = markdown.utf16.count
            applied.append(edit)
            markdown += edit.replacement
            start = range.upperBound
        }
        markdown += base[start...]
        return (markdown, applied)
    }
}
