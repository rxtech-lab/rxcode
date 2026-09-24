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
    func reasoningLevels(for provider: AgentProvider) -> [ReasoningLevel] {
        reasoningLevelsByProvider[provider] ?? []
    }

    /// Ask a provider's backend what it accepts, and cache it.
    ///
    /// Cached per provider rather than fetched per menu-open because the answer
    /// is a property of the agent binary, not of the thread, and the menu would
    /// otherwise have to render before the answer arrived.
    func loadReasoningLevels(for provider: AgentProvider) async {
        guard reasoningLevelsByProvider[provider] == nil else { return }
        let levels = await backend(for: provider).availableReasoningLevels()
        reasoningLevelsByProvider[provider] = levels
    }

    /// The effort to actually send to `provider`, or `nil` if it wouldn't take it.
    ///
    /// The single guard for every send path. It has to exist because effort is
    /// chosen in places that don't know the provider — the global Settings
    /// default spans all of them, and a session carries its pick across a
    /// provider switch — so by the time a value reaches a backend it may be a
    /// level that agent rejects. Claude would launch with `--effort minimal`;
    /// codex would fail its whole config on `max`.
    ///
    /// Unlike `reconcileSessionEffort(in:provider:)`, this awaits the level
    /// list rather than skipping when the cache is cold: a send cannot be
    /// deferred, and guessing here is what the guard exists to prevent. An
    /// agent with no reasoning control at all (ACP) yields `nil`.
    ///
    /// Dropping rather than substituting is deliberate — `nil` means "the
    /// agent's own default", which is the honest reading of a level this agent
    /// doesn't have.
    func sanitizedEffort(_ effort: String?, for provider: AgentProvider) async -> String? {
        guard let effort else { return nil }
        await loadReasoningLevels(for: provider)
        guard reasoningLevels(for: provider).contains(where: { $0.id == effort }) else {
            logger.info("[Effort] dropped \(effort, privacy: .public) — \(provider.rawValue, privacy: .public) does not accept it")
            return nil
        }
        return effort
    }

    /// Drop a session's effort when it isn't a level the provider accepts.
    ///
    /// Switching Claude → Codex used to leave `xhigh` or `max` selected, and
    /// the picker would keep showing it even though Codex rejects both. Falling
    /// back to Auto is the honest reading of "the level you picked doesn't
    /// exist here" — it is what an unset effort already means.
    func reconcileSessionEffort(in window: WindowState, provider: AgentProvider) {
        guard let effort = window.sessionEffort else { return }
        let levels = reasoningLevels(for: provider)
        // An empty list means the answer hasn't arrived yet (or the provider has
        // no control at all). Neither is grounds for discarding the user's pick.
        guard !levels.isEmpty, !levels.contains(where: { $0.id == effort }) else { return }
        setSessionEffort(nil, in: window)
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
    func defaultEffortTitle(for provider: AgentProvider) -> String {
        guard selectedEffort != "auto",
              let level = reasoningLevels(for: provider).first(where: { $0.id == selectedEffort })
        else { return "Agent default" }
        return "Settings (\(level.displayName))"
    }
}
