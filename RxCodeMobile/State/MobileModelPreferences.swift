import Foundation
import RxCodeCore
import RxCodeSync

extension MobileSettingsSnapshot {
    func reasoningLevels(for provider: AgentProvider?, model: String?) -> [ReasoningLevel] {
        guard let provider, let model else { return [] }
        return reasoningLevelsByModel?[AgentModel.key(for: model, provider: provider)] ?? []
    }

    func defaultEffortTitle(for provider: AgentProvider?, model: String?) -> String {
        let levels = reasoningLevels(for: provider, model: model)
        if let level = levels.first(where: { $0.id == selectedEffort }) {
            return String(localized: "Settings (\(level.displayName))")
        }
        return String(localized: "Agent default")
    }
}

enum MobileModelPreferences {
    private static let key = "mobile.lastModelSelection"

    static func selection(in settings: MobileSettingsSnapshot?, defaults: UserDefaults = .standard) -> TaskAgentConfig? {
        guard let settings,
              let data = defaults.data(forKey: key),
              var pick = try? JSONDecoder().decode(TaskAgentConfig.self, from: data),
              let provider = pick.provider, let model = pick.model
        else { return nil }
        let catalog = settings.modelSections?.flatMap(\.models) ?? []
        let models = catalog.isEmpty ? settings.availableModels ?? [] : catalog
        guard models.contains(where: { $0.provider == provider && $0.id == model }) else { return nil }
        if !settings.reasoningLevels(for: provider, model: model).contains(where: { $0.id == pick.effort }) {
            pick.effort = nil
        }
        return pick
    }

    static func remember(provider: AgentProvider?, model: String?, effort: String?, defaults: UserDefaults = .standard) {
        guard let provider, let model else {
            defaults.removeObject(forKey: key)
            return
        }
        let pick = TaskAgentConfig(provider: provider, model: model, effort: effort)
        if let data = try? JSONEncoder().encode(pick) {
            defaults.set(data, forKey: key)
        }
    }
}
