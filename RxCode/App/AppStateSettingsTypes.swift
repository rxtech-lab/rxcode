import Foundation

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

