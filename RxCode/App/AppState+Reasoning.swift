import Foundation
import os
import RxCodeCore

extension AppState {
    /// The thinking levels the given provider accepts.
    ///
    /// Empty until `loadReasoningLevels(for:)` has answered, and empty forever
    /// for a provider with no reasoning control — the picker reads both the
    /// same way and hides itself, which is the right thing to show while the
    /// answer is still in flight.
    func reasoningLevels(for provider: AgentProvider, model: String? = nil) -> [ReasoningLevel] {
        if provider == .codex, let model, let levels = codexLevelsByModel[model] { return levels }
        return reasoningLevelsByProvider[provider] ?? []
    }

    /// Ask a provider's backend what it accepts, and cache it.
    ///
    /// Cached per provider rather than fetched per menu-open because the answer
    /// is a property of the agent binary, not of the thread, and the menu would
    /// otherwise have to render before the answer arrived.
    func loadReasoningLevels(for provider: AgentProvider) async {
        guard reasoningLevelsByProvider[provider] == nil else { return }
        let levels = await backend(for: provider).availableReasoningLevels()
        if provider == .codex, agentBackendOverrides[provider] == nil {
            codexLevelsByModel = await codex.modelReasoningLevels
        }
        if !levels.isEmpty || (provider != .codex && provider != .claudeCode) {
            reasoningLevelsByProvider[provider] = levels
        }
    }

    /// The effort to actually send to `provider`, or `nil` if it wouldn't take it.
    func sanitizedEffort(_ effort: String?, for provider: AgentProvider, model: String? = nil) async -> String? {
        guard let effort else { return nil }
        await loadReasoningLevels(for: provider)
        guard reasoningLevels(for: provider, model: model).contains(where: { $0.id == effort }) else {
            logger.info("[Effort] dropped \(effort, privacy: .public) — \(provider.rawValue, privacy: .public) does not accept it")
            return nil
        }
        return effort
    }

    /// Drop a session's effort when it isn't a level the provider accepts.
    func reconcileSessionEffort(in window: WindowState, provider: AgentProvider) {
        guard let effort = window.sessionEffort else { return }
        let levels = reasoningLevels(for: provider, model: effectiveModelSelection(in: window).model)
        // An empty list means the answer hasn't arrived yet (or the provider has
        // no control at all). Neither is grounds for discarding the user's pick.
        guard !levels.isEmpty, !levels.contains(where: { $0.id == effort }) else { return }
        updateSessionEffort(nil, in: window)
    }

    func effectiveSessionEffort(in window: WindowState) -> String? {
        if let effort = window.sessionEffort { return effort }
        return window.currentSessionId == nil ? rememberedProjectEffort(in: window) : nil
    }

    func rememberedProjectEffort(in window: WindowState) -> String? {
        guard let project = window.selectedProject else { return nil }
        let selection = effectiveModelSelection(in: window)
        let key = AgentModel.key(for: selection.model, provider: selection.provider)
        let efforts = project.isGlobalChat
            ? globalChatEffortsByModel
            : projects.first(where: { $0.id == project.id })?.effortsByModel
        guard let effort = efforts?[key] else { return nil }
        let levels = reasoningLevels(for: selection.provider, model: selection.model)
        return levels.isEmpty || levels.contains(where: { $0.id == effort }) ? effort : nil
    }

    func rememberProjectEffort(_ effort: String?, in window: WindowState) -> Bool {
        guard let project = window.selectedProject else { return false }
        let selection = effectiveModelSelection(in: window)
        let key = AgentModel.key(for: selection.model, provider: selection.provider)
        if project.isGlobalChat {
            if globalChatEffortsByModel[key] != effort { globalChatEffortsByModel[key] = effort }
            return true
        }

        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return false }
        var efforts = projects[index].effortsByModel ?? [:]
        guard efforts[key] != effort else { return true }
        efforts[key] = effort
        projects[index].effortsByModel = efforts.isEmpty ? nil : efforts
        saveProjectChatPreferences()
        return true
    }

    /// Names what clearing a session's effort actually falls back to.
    ///
    /// The pickers used to call that row "Auto", which reads as "the agent
    /// decides" — it isn't. An unpinned session sends the global Settings
    /// effort, and only when that is itself unset does the agent's own default
    /// apply. Saying which of the two is in force is the difference between a
    /// row the user can reason about and one they have to test.
    ///
    /// A Settings level the provider doesn't accept is reported as the agent
    /// default, because that is what `sanitizedEffort(_:for:)` will do with it.
    func defaultEffortTitle(for provider: AgentProvider, model: String? = nil) -> String {
        guard selectedEffort != "auto",
              let level = reasoningLevels(for: provider, model: model).first(where: { $0.id == selectedEffort })
        else { return "Agent default" }
        return "Settings (\(level.displayName))"
    }
}
