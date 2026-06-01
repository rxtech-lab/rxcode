import Foundation

// Codable DTOs for github-pm's repo-setup templates
// (`/api/v1/repo-setup/templates`). A template bundles GitHub merge settings
// (rendered from a JSON schema) with an optional raw GitHub ruleset.

// MARK: - Template

public struct RepoSetupTemplate: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public var isDefault: Bool
    /// GitHub PR merge settings; shape defined by the repo-setup JSON schema.
    public var mergeSettings: JSONValue
    /// Raw GitHub ruleset JSON, or `nil` when no ruleset is attached.
    public var rulesetConfig: JSONValue?

    public init(
        id: String,
        name: String,
        enabled: Bool,
        isDefault: Bool,
        mergeSettings: JSONValue,
        rulesetConfig: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.isDefault = isDefault
        self.mergeSettings = mergeSettings
        self.rulesetConfig = rulesetConfig
    }
}

public struct RepoSetupTemplateList: Codable, Sendable {
    public let items: [RepoSetupTemplate]

    public init(items: [RepoSetupTemplate]) {
        self.items = items
    }
}

/// Create/update payload for a repo-setup template.
public struct RepoSetupTemplateInput: Codable, Sendable {
    public var name: String
    public var enabled: Bool
    public var isDefault: Bool
    public var mergeSettings: JSONValue
    public var rulesetConfig: JSONValue?

    public init(
        name: String,
        enabled: Bool,
        isDefault: Bool,
        mergeSettings: JSONValue,
        rulesetConfig: JSONValue? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.isDefault = isDefault
        self.mergeSettings = mergeSettings
        self.rulesetConfig = rulesetConfig
    }
}

// MARK: - GitHub ruleset validation

/// A validated summary of a raw GitHub ruleset JSON, mirroring the webapp's
/// upload check (`components/repo-setup/template-form.tsx`): the JSON must be an
/// object carrying `name`, `target`, `enforcement`, and `rules`.
public struct GitHubRulesetSummary: Sendable, Equatable {
    public let name: String
    public let target: String
    public let enforcement: String
    public let ruleCount: Int
    /// The parsed ruleset, ready to store as a template's `rulesetConfig`.
    public let value: JSONValue

    public enum ValidationError: Error, Equatable, LocalizedError {
        case empty
        case invalidJSON
        case notAnObject
        case missingFields([String])

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste or import a GitHub ruleset JSON."
            case .invalidJSON:
                return "Invalid JSON. Please check the file format."
            case .notAnObject:
                return "A ruleset must be a JSON object."
            case .missingFields(let fields):
                return "Invalid ruleset format. Missing: \(fields.joined(separator: ", ")). Expected name, target, enforcement, and rules."
            }
        }
    }

    /// Parses and validates a raw GitHub ruleset JSON string.
    public static func validate(rawJSON: String) -> Result<GitHubRulesetSummary, ValidationError> {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONValue(jsonData: data)
        else { return .failure(.invalidJSON) }
        guard case .object(let fields) = parsed else { return .failure(.notAnObject) }

        var missing: [String] = []
        let name = fields["name"]?.stringValue
        let target = fields["target"]?.stringValue
        let enforcement = fields["enforcement"]?.stringValue
        let rules = fields["rules"]?.arrayValue

        if name == nil { missing.append("name") }
        if target == nil { missing.append("target") }
        if enforcement == nil { missing.append("enforcement") }
        if rules == nil { missing.append("rules") }
        guard missing.isEmpty,
              let name, let target, let enforcement, let rules
        else { return .failure(.missingFields(missing)) }

        return .success(
            GitHubRulesetSummary(
                name: name,
                target: target,
                enforcement: enforcement,
                ruleCount: rules.count,
                value: parsed
            )
        )
    }
}
