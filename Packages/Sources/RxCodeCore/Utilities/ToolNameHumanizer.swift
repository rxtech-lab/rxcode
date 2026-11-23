import Foundation
import FoundationModels

/// Generates action labels for external tool identifiers using the on-device model.
public actor ToolNameHumanizer {
    public static let shared = ToolNameHumanizer(generate: generateLabel)

    private let generate: @Sendable (String) async -> String?
    private let labels = NSCache<NSString, NSString>()
    private var pending: [String: Task<String?, Never>] = [:]
    private var lastGeneration: Task<String?, Never>?

    init(generate: @escaping @Sendable (String) async -> String?) {
        self.generate = generate
        labels.countLimit = 512
    }

    /// Returns nil when the model is unavailable or does not produce a usable label.
    public func label(for identifier: String) async -> String? {
        guard !identifier.isEmpty, identifier.utf8.count <= 256,
              identifier.allSatisfy({ $0.isLetter || $0.isNumber || "_-./:".contains($0) })
        else { return nil }

        if let cached = labels.object(forKey: identifier as NSString) { return cached as String }
        if let existing = pending[identifier] { return await existing.value }

        // A restored transcript can request many distinct labels in the same frame.
        // Submit one generation at a time, sharing work across matching tool calls.
        let previous = lastGeneration
        let task = Task { [generate] in
            _ = await previous?.value
            return await generate(identifier).flatMap(Self.clean)
        }
        pending[identifier] = task
        lastGeneration = task
        let label = await task.value
        pending[identifier] = nil
        if pending.isEmpty { lastGeneration = nil }
        if let label { labels.setObject(label as NSString, forKey: identifier as NSString) }
        return label
    }

    private static func generateLabel(for identifier: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            Convert the tool identifier to a short English activity label in sentence case.
            Begin with a verb ending in -ing and name its object. Ignore protocol and server prefixes.
            For example, mcp__calendar__list_events becomes Listing calendar events.
            Return only the label, with no punctuation or explanation.
            """)
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: 32)
        return try? await session.respond(to: identifier, options: options).content
    }

    private static func clean(_ response: String) -> String? {
        let label = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"."))
        let words = label.split(separator: " ")
        guard label.count <= 64, (1...8).contains(words.count),
              words.first?.lowercased().hasSuffix("ing") == true,
              label.allSatisfy({ $0.isLetter || $0.isNumber || " -'’".contains($0) })
        else { return nil }
        let normalized = words.joined(separator: " ")
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
    }
}
