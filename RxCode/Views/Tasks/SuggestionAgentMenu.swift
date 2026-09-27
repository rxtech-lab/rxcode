import RxCodeCore
import SwiftUI

/// Picks the model that powers general AI tasks — drafting, titles, auto-fill,
/// cron, filter scripts and context-menu conditions. The choice is saved as the
/// Settings → Message general AI model, so every form and the settings tab stay
/// in agreement.
struct SuggestionAgentMenu: View {
    @Environment(AppState.self) private var appState

    @Binding var agent: GeneralAIModel

    var body: some View {
        Menu {
            Button("Default task agent") { select(.taskAgent) }
            if FoundationModelSummarizationService.isAvailable || agent == .appleIntelligence {
                Button("Apple Intelligence (On-Device)") { select(.appleIntelligence) }
            }
            Divider()
            ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { model in
                        Button(model.displayName) {
                            select(.agent(TaskAgentConfig(provider: model.provider, model: model.id)))
                        }
                    }
                }
            }
        } label: {
            TaskBoardChipLabel(
                icon: agent == .appleIntelligence ? "apple.intelligence" : "sparkles",
                title: appState.generalAIModelLabel(agent),
                isActive: agent != .taskAgent
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The model that runs general AI tasks")
    }

    private func select(_ newValue: GeneralAIModel) {
        appState.setGeneralAIModel(newValue)
        agent = newValue
    }
}
