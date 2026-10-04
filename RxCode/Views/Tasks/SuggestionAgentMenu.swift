import RxCodeCore
import SwiftUI

/// Picks a general AI model. Most callers save the choice in Settings; a
/// one-off suggestion can keep its selection local to the current view.
struct SuggestionAgentMenu: View {
    @Environment(AppState.self) private var appState

    @Binding var agent: GeneralAIModel
    var persistsSelection = true

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
        .help(persistsSelection ? "The model that runs general AI tasks" : "The model for this suggestion")
    }

    private func select(_ newValue: GeneralAIModel) {
        if persistsSelection { appState.setGeneralAIModel(newValue) }
        agent = newValue
    }
}
