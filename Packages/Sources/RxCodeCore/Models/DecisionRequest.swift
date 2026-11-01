import Foundation

/// One question for a local decision model, as the decision studio sends it.
///
/// It travels as the user message's plain text so the thread keeps a
/// readable record and the decision tool can read it back:
///
///     Which team should handle this ticket?
///
///     Options:
///     - billing: payments, invoices, refunds
///     - technical
///
/// Without options the question is a statement judged true or false.
public struct DecisionRequest: Equatable, Sendable {
    public struct Option: Codable, Equatable, Hashable, Sendable {
        public var name: String
        /// What choosing it means; empty when the name says enough.
        public var detail: String

        public init(name: String, detail: String = "") {
            self.name = name
            self.detail = detail
        }
    }

    public static let optionsHeader = "Options:"
    public static let maxOptions = 20

    public var question: String
    public var options: [Option]

    public init(question: String, options: [Option] = []) {
        self.question = question
        self.options = options
    }

    /// True/false when there are fewer than two options.
    public var isStatement: Bool { options.count < 2 }

    public var messageText: String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStatement else { return question }
        let lines = options.map { $0.detail.isEmpty ? "- \($0.name)" : "- \($0.name): \($0.detail)" }
        return "\(question)\n\n\(Self.optionsHeader)\n" + lines.joined(separator: "\n")
    }

    /// Reads `messageText` back. Lines before the options header are the
    /// question; duplicate and empty options are dropped.
    public static func parse(_ text: String) -> DecisionRequest {
        var lines = text.components(separatedBy: .newlines)
        guard let header = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(optionsHeader) == .orderedSame
        }) else {
            return DecisionRequest(question: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let optionLines = lines[(header + 1)...]
        lines.removeSubrange(header...)
        var seen = Set<String>()
        var options: [Option] = []
        for line in optionLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let parts = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            options.append(Option(name: name, detail: parts.count > 1 ? parts[1] : ""))
        }
        return DecisionRequest(
            question: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            options: Array(options.prefix(maxOptions))
        )
    }
}

/// The decision composer's options and web search choice, kept per window
/// until the user changes them.
public struct DecisionDraft: Equatable, Sendable {
    public var options: [DecisionRequest.Option] = []

    public init(options: [DecisionRequest.Option] = []) {
        self.options = options
    }
}

/// Decision studio settings that apply to every future decision.
public struct DecisionSettings: Codable, Equatable, Sendable {
    public static let storageKey = "localDecisionSettings"

    /// Search the web for the question and judge with the results as context.
    public var searchWeb = true
    public var maxSources = 5

    public init() {}

    public var validated: Self {
        var value = self
        value.maxSources = min(10, max(1, maxSources))
        return value
    }

    public var encoded: String {
        guard let data = try? JSONEncoder().encode(validated) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ string: String) -> Self {
        ((try? JSONDecoder().decode(Self.self, from: Data(string.utf8))) ?? Self()).validated
    }

    public static func load() -> Self {
        decode(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

/// The `Decision` tool's result, as the decision studio reads it.
public struct DecisionResult: Codable, Equatable, Sendable {
    public struct Score: Codable, Equatable, Sendable {
        public let name: String
        public let detail: String
        /// Calibrated, summing to 1 over all options.
        public let probability: Double
        /// logit(" yes") − logit(" no") at the option's verdict slot.
        public let score: Double

        public init(name: String, detail: String, probability: Double, score: Double) {
            self.name = name
            self.detail = detail
            self.probability = probability
            self.score = score
        }
    }

    public struct Source: Codable, Equatable, Sendable, Identifiable {
        public var id: String { url }
        public let title: String
        public let url: String
        public let snippet: String

        public init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }
    }

    public let question: String
    /// `"choice"` or `"statement"`.
    public let type: String
    public let scores: [Score]
    public let answer: String
    public let sources: [Source]
    public let model: String
    public let elapsedSeconds: Int
    /// "Calibrated" when the model shipped a readout config, else "Uncalibrated".
    public let calibration: String

    public init(
        question: String, type: String, scores: [Score], answer: String, sources: [Source],
        model: String, elapsedSeconds: Int, calibration: String
    ) {
        self.question = question
        self.type = type
        self.scores = scores
        self.answer = answer
        self.sources = sources
        self.model = model
        self.elapsedSeconds = elapsedSeconds
        self.calibration = calibration
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(_ string: String?) -> DecisionResult? {
        guard let string else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(string.utf8))
    }
}
