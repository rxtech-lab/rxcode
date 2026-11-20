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
            ("claudeCode", AgentProvider.claudeCode.displayNameText, .claudeCode, nil, claudeModels.isEmpty ? Self.availableClaudeModels : claudeModels),
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

    /// The studio a model id opens in: `.chat` for every model but a
    /// downloaded local video, image, audio or decision model.
    func localStudioKind(_ id: String, provider: AgentProvider) -> LocalStudioKind {
        guard provider == .localAgent else { return .chat }
        return localModels.model(id: id)?.studioKind ?? .chat
    }

    /// Whether a model id names a downloaded local video model.
    func isLocalVideoModel(_ id: String, provider: AgentProvider) -> Bool {
        localStudioKind(id, provider: provider) == .video
    }

    /// The studio a started thread is locked to. Its history is prompts and
    /// results of that kind (clips, images, audio or decisions), which a
    /// model of another kind can't continue. A new chat is free to pick any
    /// model.
    func lockedStudioKind(in window: WindowState) -> LocalStudioKind? {
        guard window.currentSessionId != nil else { return nil }
        let selection = effectiveModelSelection(in: window)
        let kind = localStudioKind(selection.model, provider: selection.provider)
        return kind.isStudio ? kind : nil
    }

    func isVideoModelLocked(in window: WindowState) -> Bool {
        lockedStudioKind(in: window) == .video
    }

    /// The sections a window's model pickers offer: only models of the same
    /// studio once a studio thread has started, otherwise everything.
    func availableAgentModelSections(in window: WindowState) -> [(id: String, title: String, provider: AgentProvider, iconURL: String?, models: [AgentModel])] {
        let sections = availableAgentModelSections()
        guard let kind = lockedStudioKind(in: window) else { return sections }
        return sections.compactMap { section in
            let models = section.models.filter { localStudioKind($0.id, provider: $0.provider) == kind }
            return models.isEmpty ? nil : (section.id, section.title, section.provider, section.iconURL, models)
        }
    }

    /// False for a model of another kind while a studio thread is locked.
    func canSelectModel(_ model: String, provider: AgentProvider, in window: WindowState) -> Bool {
        guard let kind = lockedStudioKind(in: window), localStudioKind(model, provider: provider) != kind else { return true }
        logger.info("[Model] ignored switch to \(model, privacy: .public): \(kind.rawValue, privacy: .public) threads only take \(kind.rawValue, privacy: .public) models")
        return false
    }

    func setDefaultAgentProvider(_ provider: AgentProvider) {
        guard provider != selectedAgentProvider else { return }

        selectedAgentProvider = provider
        if let model = availableAgentModelSections()
            .first(where: { $0.provider == provider })?
            .models
            .first?
            .id
        {
            selectedModel = model
        }
    }

    func isModelAvailable(_ model: String, provider: AgentProvider) -> Bool {
        availableAgentModelSections()
            .flatMap(\.models)
            .contains { $0.provider == provider && $0.id == model }
    }

    func projectDefaultModelSelection(for project: Project?) -> (provider: AgentProvider, model: String)? {
        guard let project,
              let provider = project.isGlobalChat ? globalChatLastAgentProvider : project.lastAgentProvider,
              let model = project.isGlobalChat ? globalChatLastModel : project.lastModel,
              isModelAvailable(model, provider: provider)
        else {
            return nil
        }
        return (provider, model)
    }

    func defaultModelSelection(for project: Project?) -> (provider: AgentProvider, model: String) {
        projectDefaultModelSelection(for: project) ?? (selectedAgentProvider, selectedModel)
    }

    func fallbackModel(for provider: AgentProvider, project: Project?) -> String {
        if let projectSelection = projectDefaultModelSelection(for: project),
           projectSelection.provider == provider {
            return projectSelection.model
        }
        if selectedAgentProvider == provider {
            return selectedModel
        }
        return availableAgentModelSections()
            .first { $0.provider == provider }?
            .models
            .first?
            .id ?? selectedModel
    }

    func effectiveModelSelection(in window: WindowState) -> (provider: AgentProvider, model: String) {
        if let provider = window.sessionAgentProvider {
            return (provider, window.sessionModel ?? fallbackModel(for: provider, project: window.selectedProject))
        }
        if let model = window.sessionModel {
            return (selectedAgentProvider, model)
        }
        return defaultModelSelection(for: window.selectedProject)
    }

    func rememberProjectModelSelection(_ model: String, provider: AgentProvider, in window: WindowState) {
        if window.selectedProject?.isGlobalChat == true {
            globalChatLastAgentProvider = provider
            globalChatLastModel = model
            return
        }

        guard let project = window.selectedProject,
              let index = projects.firstIndex(where: { $0.id == project.id })
        else {
            return
        }

        guard projects[index].lastAgentProvider != provider || projects[index].lastModel != model else {
            return
        }

        projects[index].lastAgentProvider = provider
        projects[index].lastModel = model
        window.selectedProject = projects[index]
        saveProjectChatPreferences()
    }

    /// Sets the model for the current session and persists it in the session state.
    func setSessionModel(_ model: String, provider: AgentProvider? = nil, in window: WindowState) {
        let previous = effectiveModelSelection(in: window)
        let resolvedProvider = provider ?? previous.provider
        guard canSelectModel(model, provider: resolvedProvider, in: window) else { return }
        let modelChanged = previous.provider != resolvedProvider || previous.model != model
        window.sessionAgentProvider = resolvedProvider
        window.sessionModel = model
        if modelChanged {
            window.sessionEffort = window.currentSessionId == nil ? nil : rememberedProjectEffort(in: window)
        }
        let key = window.currentSessionId ?? window.newSessionKey
        let acpParts = resolvedProvider == .acp ? acpSelectionParts(for: model) : nil
        if let acpParts {
            selectedACPClientId = acpParts.clientId
        }
        rememberProjectModelSelection(model, provider: resolvedProvider, in: window)
        updateState(key) { state in
            state.agentProvider = resolvedProvider
            state.model = model
            if modelChanged { state.setEffort(window.sessionEffort) }
            state.acpClientId = acpParts?.clientId
            // Drop the cached CLI-reported name so the status line reflects the
            // user's choice immediately; the next system event will refill it.
            state.activeModelName = nil
        }
    }

    /// Sets only the active client for the current session. The model is resolved to the
    /// current default for that client when possible, otherwise the first available model.
    func setSessionProvider(_ provider: AgentProvider, in window: WindowState) {
        guard provider != effectiveModelSelection(in: window).provider else { return }

        let fallbackModel = availableAgentModelSections()
            .first { $0.provider == provider }?
            .models
            .first?
            .id
        let model = selectedAgentProvider == provider ? selectedModel : (fallbackModel ?? selectedModel)
        setSessionModel(model, provider: provider, in: window)
    }

    func modelDisplayName(for model: String, provider: AgentProvider, in window: WindowState) -> String {
        // The local agent reports its raw model id; keep the friendly label instead.
        if provider != .localAgent, let active = activeModelName(in: window) {
            return active
        }
        return modelDisplayLabel(model, provider: provider)
    }

    /// Remembers a user pick for this model and applies it to the current chat.
    func setSessionEffort(_ effort: String?, in window: WindowState) {
        let remembered = rememberProjectEffort(effort, in: window)
        // Drafts follow the preference for whichever model they resolve to.
        updateSessionEffort(window.currentSessionId == nil && remembered ? nil : effort, in: window)
    }

    /// Applies a session-only effort for model compatibility or automated runs.
    func updateSessionEffort(_ effort: String?, in window: WindowState) {
        window.sessionEffort = effort
        let key = window.currentSessionId ?? window.newSessionKey
        updateState(key) { $0.setEffort(effort) }
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
        if provider == .localAgent {
            if let info = localModels.installed.first(where: { $0.id == model }) { return info.displayName }
            // Not installed (anymore): show the file or repo name without its path or extension.
            let name = model.split(separator: "/").last.map(String.init) ?? model
            return name.hasSuffix(".gguf") ? String(name.dropLast(5)) : name
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
    var availableEfforts: [String] {
        let ordered = reasoningLevels(for: .codex) + reasoningLevels(for: .claudeCode)
        var seen: Set<String> = []
        return ordered.map(\.id).filter { seen.insert($0).inserted }
    }

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
