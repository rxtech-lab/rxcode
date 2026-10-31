import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Model

    static let availableModels = ["default", "best", "fable", "fable[1m]", "opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku"]
    static let fallbackCodexModels = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex"]
    nonisolated static let defaultOpenAISummarizationEndpoint = "https://api.openai.com/v1"
    nonisolated static let openAISummarizationKeychainService = "com.idealapp.RxCode.openai-summarization"
    nonisolated static let openAISummarizationKeychainAccount = "apiKey"

    static var availableClaudeModels: [AgentModel] {
        availableModels.map {
            AgentModel(provider: .claudeCode, id: $0, displayName: modelDisplayName($0), description: modelDescription($0))
        }
    }

    static func availableCodexModels(_ discovered: [AgentModel]) -> [AgentModel] {
        if !discovered.isEmpty { return discovered }
        return fallbackCodexModels.map {
            AgentModel(provider: .codex, id: $0, displayName: modelDisplayName($0, provider: .codex), description: modelDescription($0, provider: .codex))
        }
    }

    func availableAgentModelSections() -> [(id: String, title: String, provider: AgentProvider, iconURL: String?, models: [AgentModel])] {
        var sections: [(id: String, title: String, provider: AgentProvider, iconURL: String?, models: [AgentModel])] = [
            ("claudeCode", AgentProvider.claudeCode.displayNameText, .claudeCode, nil, Self.availableClaudeModels),
            ("codex", AgentProvider.codex.displayNameText, .codex, nil, Self.availableCodexModels(codexModels)),
        ]

        // RxCode's own agent appears once a local model is downloaded.
        if !localModels.installed.isEmpty {
            sections.append(("localAgent", AgentProvider.localAgent.displayNameText, .localAgent, nil,
                             localModels.installed.map {
                                 AgentModel(provider: .localAgent, id: $0.id, displayName: $0.displayName,
                                            description: Self.localModelDescription($0))
                             }))
        }

        // Preserve provider groups so subscription and separately billed models
        // remain distinguishable. Selection keys still identify the ACP client.
        for client in acpClients where client.enabled {
            let options = client.modelOptions.flatMap { $0.isEmpty ? nil : $0 }
                ?? client.models.map { ACPModelOption(value: $0, name: $0) }
            guard !options.isEmpty else {
                sections.append(("acp:\(client.id)", client.displayName, .acp, client.iconURL, [
                    AgentModel(provider: .acp, id: "\(client.id)::", displayName: "Default", description: "ACP client \(client.displayName)"),
                ]))
                continue
            }

            var groups: [(id: String?, title: String, models: [AgentModel])] = []
            for option in options {
                let group = Self.acpModelGroup(option)
                let title = group.map { "\(client.displayName) · \($0.title)" } ?? client.displayName
                let model = AgentModel(
                    provider: .acp,
                    id: "\(client.id)::\(option.value)",
                    displayName: option.name.isEmpty ? option.value : Self.stripACPProviderPrefix(option.name),
                    description: option.description ?? title
                )
                if let index = groups.firstIndex(where: { $0.id == group?.id }) {
                    groups[index].models.append(model)
                } else {
                    groups.append((group?.id, title, [model]))
                }
            }
            for group in groups {
                let id = group.id.map { "acp:\(client.id):group:\($0)" } ?? "acp:\(client.id)"
                sections.append((id, group.title, .acp, client.iconURL, group.models))
            }
        }
        return sections
    }

    static func localModelDescription(_ model: LocalModelInfo) -> String {
        [LocalModelFormat.parameters(model.parameterCount).map { "\($0) parameters" },
         LocalModelFormat.bytes(model.sizeBytes), "by \(model.author)"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Splits an ACP model key `<clientId>::<model>` into its parts.
    static func splitACPModelKey(_ key: String) -> (clientId: String, model: String)? {
        let parts = key.components(separatedBy: "::")
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    func acpSelectionParts(for model: String?) -> (clientId: String, model: String)? {
        guard let model, !model.isEmpty else { return nil }
        if let parts = Self.splitACPModelKey(model) {
            return parts
        }
        if acpClients.contains(where: { $0.id == model }) {
            return (model, "")
        }
        if !selectedACPClientId.isEmpty {
            return (selectedACPClientId, model)
        }
        if let client = acpClients.first(where: { $0.enabled && ($0.modelOptions?.contains(where: { $0.value == model }) ?? false) }) {
            return (client.id, model)
        }
        if let client = acpClients.first(where: { $0.enabled && $0.models.contains(model) }) {
            return (client.id, model)
        }
        return nil
    }

    func acpModelDisplayName(client: ACPClientSpec, model: String) -> String {
        if model.isEmpty {
            return "Default"
        }
        if let option = client.modelOptions?.first(where: { $0.value == model }),
           !option.name.isEmpty
        {
            let name = Self.stripACPProviderPrefix(option.name)
            if let group = Self.acpModelGroup(option) {
                return "\(group.title) · \(name)"
            }
            return name
        }
        return model
    }

    /// Older saved options lack group metadata but often retain provider-prefixed names.
    static func acpModelGroup(_ option: ACPModelOption) -> (id: String, title: String)? {
        if let id = option.groupId, !id.isEmpty {
            let name = option.groupName.flatMap { $0.isEmpty ? nil : $0 } ?? id
            return (id, name)
        }
        if let name = option.groupName, !name.isEmpty { return (name, name) }
        // OpenCode IDs identify the billing provider even in older cached lists.
        let components = option.value.split(separator: "/", maxSplits: 1)
        if components.count == 2 {
            switch components[0] {
            case "opencode-go": return ("opencode-go", "OpenCode Go")
            case "opencode": return ("opencode", "OpenCode Zen")
            default: break
            }
        }
        if option.name != option.value, let slash = option.name.firstIndex(of: "/") {
            let prefix = option.name[..<slash].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { return (prefix, prefix) }
        }
        return nil
    }

    /// Drops the leading `<provider>/` segment from an ACP model option name
    /// when the picker already shows the provider group. Example:
    /// `"OpenCode Zen/MiniMax M2.5 Free"` → `"MiniMax M2.5 Free"`. Names
    /// without a `/` are returned unchanged.
    static func stripACPProviderPrefix(_ name: String) -> String {
        guard let slash = name.lastIndex(of: "/") else { return name }
        let tail = name[name.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? name : String(tail)
    }

    /// Human-readable label for a model id, resolving ACP keys (`<clientId>::<model>`)
    /// to the client's display name plus the underlying model id ("Default" when empty).
    func modelDisplayLabel(_ model: String, provider: AgentProvider) -> String {
        if provider == .acp, let parts = acpSelectionParts(for: model) {
            guard let client = acpClients.first(where: { $0.id == parts.clientId }) else {
                return parts.model.isEmpty ? "ACP · Default" : "ACP · \(parts.model)"
            }
            return "\(client.displayName) · \(acpModelDisplayName(client: client, model: parts.model))"
        }
        return Self.modelDisplayName(model, provider: provider)
    }

    static func modelDisplayName(_ model: String) -> String {
        modelDisplayName(model, provider: .claudeCode)
    }

    static func modelDisplayName(_ model: String, provider: AgentProvider) -> String {
        if provider == .codex {
            return model
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { part in
                    part.uppercased().hasPrefix("GPT") ? part.uppercased() : part.capitalized
                }
                .joined(separator: " ")
        }
        switch model {
        case "default": return "Default"
        case "best": return "Best"
        case "fable": return "Fable"
        case "fable[1m]": return "Fable 1M"
        case "opus": return "Opus"
        case "opus[1m]": return "Opus 1M"
        case "sonnet": return "Sonnet"
        case "sonnet[1m]": return "Sonnet 1M"
        case "haiku": return "Haiku"
        default: return model.capitalized
        }
    }

    static func modelDescription(_ model: String) -> String {
        modelDescription(model, provider: .claudeCode)
    }

    static func modelDescription(_ model: String, provider: AgentProvider) -> String {
        if provider == .codex {
            switch model {
            case "gpt-5.4": return "Balanced Codex model for everyday coding."
            case "gpt-5.4-mini": return "Fast Codex model for lighter coding tasks."
            case "gpt-5.3-codex": return "Codex-optimized coding model."
            default: return "Codex model served by the Codex app-server."
            }
        }
        let key: String
        switch model {
        case "default": key = "model.desc.default"
        case "best": key = "model.desc.best"
        case "fable": key = "model.desc.fable"
        case "fable[1m]": key = "model.desc.fable1m"
        case "opus": key = "model.desc.opus"
        case "opus[1m]": key = "model.desc.opus1m"
        case "sonnet": key = "model.desc.sonnet"
        case "sonnet[1m]": key = "model.desc.sonnet1m"
        case "haiku": key = "model.desc.haiku"
        default: return ""
        }
        return NSLocalizedString(key, comment: "")
    }

    /// Every level any provider accepts, deduplicated in ascending order.
    ///
    /// Only for the *global default* in Settings, which is chosen before a
    /// provider is known. Anything scoped to a thread asks that thread's
    /// backend via `reasoningLevels(for:)` — Claude and Codex do not accept the
    /// same values, so the union is wrong for both individually.
    static let availableEfforts: [String] = {
        let ordered = [ReasoningLevel].codexEfforts + [ReasoningLevel].claudeCodeEfforts
        var seen: Set<String> = []
        return ordered.map(\.id).filter { seen.insert($0).inserted }
    }()

    static func permissionModeDescription(_ mode: PermissionMode) -> String {
        let key: String
        switch mode {
        case .default: key = "perm.desc.default"
        case .acceptEdits: key = "perm.desc.acceptEdits"
        case .plan: key = "perm.desc.plan"
        case .auto: key = "perm.desc.auto"
        case .bypassPermissions: key = "perm.desc.bypassPermissions"
        }
        return NSLocalizedString(key, comment: "")
    }

    static func effortDescription(_ effort: String) -> String {
        let key: String
        switch effort {
        case "auto": key = "effort.desc.auto"
        case "low": key = "effort.desc.low"
        case "medium": key = "effort.desc.medium"
        case "high": key = "effort.desc.high"
        case "xhigh": key = "effort.desc.xhigh"
        case "max": key = "effort.desc.max"
        default: return ""
        }
        return NSLocalizedString(key, comment: "")
    }
}
