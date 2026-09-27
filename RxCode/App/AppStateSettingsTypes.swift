import Foundation
import RxCodeCore

enum SummarizationProvider: String, CaseIterable, Identifiable {
    case selectedClient
    case openAI
    case appleFoundationModel

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .selectedClient: return "Thread Model"
        case .openAI: return "OpenAI-Compatible Endpoint"
        case .appleFoundationModel: return "Apple Foundation Model"
        }
    }

    var displayNameText: String {
        String(localized: displayName)
    }

    /// Returns the providers that should be offered to the user right now.
    /// Apple Foundation Model is hidden when the device doesn't support it
    /// (non-Apple-Silicon Mac, Apple Intelligence disabled, etc.).
    @MainActor
    static var availableCases: [SummarizationProvider] {
        allCases.filter { provider in
            switch provider {
            case .appleFoundationModel:
                return FoundationModelSummarizationService.isAvailable
            case .selectedClient, .openAI:
                return true
            }
        }
    }
}

enum MemoryRetrievalMode: String, CaseIterable, Identifiable {
    case precise
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precise: return "Precise"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        }
    }

    var scoreThreshold: Float {
        switch self {
        case .precise: return 0.65
        case .balanced: return 0.50
        case .aggressive: return 0.35
        }
    }
}


/// The model that runs general AI tasks — drafting tasks and stories from
/// natural language, form Auto-fill, cron schedules, filter scripts and
/// context-menu conditions. Chosen in Settings → Message.
enum GeneralAIModel: Hashable {
    /// Follow the default task agent from Settings → Tasks.
    case taskAgent
    /// Apple's on-device Foundation Model.
    case appleIntelligence
    /// A Claude Code, Codex or ACP model.
    case agent(TaskAgentConfig)

    /// Stored in place of a provider raw value to mark Apple Intelligence.
    static let appleIntelligenceKey = "appleIntelligence"
}
