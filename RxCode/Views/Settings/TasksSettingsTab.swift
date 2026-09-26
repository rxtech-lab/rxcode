import RxCodeCore
import SwiftUI

/// "Tasks" tab in SettingsView: the agent new tasks are assigned to, and
/// whether quick-added tasks get their properties filled in by that agent.
struct TasksSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// Mirrors the persisted setting, which lives in workspace defaults and
    /// isn't observable on its own.
    @State private var configured: TaskAgentConfig?
    @State private var suggestionAgent: TaskAgentConfig?
    @State private var autoClassify = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Default agent") {
                    Menu {
                        Button("Last used") { select(nil) }
                        Divider()
                        ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                            Section(section.title) {
                                ForEach(section.models, id: \.key) { model in
                                    Button(model.displayName) {
                                        select(TaskAgentConfig(provider: model.provider, model: model.id))
                                    }
                                }
                            }
                        }
                    } label: {
                        TaskBoardChipLabel(
                            icon: "sparkles",
                            title: agentTitle,
                            isActive: configured != nil
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            } header: {
                Text("New Tasks")
            } footer: {
                Text("New tasks are assigned this agent. “Last used” keeps the model most recently picked in a task form.")
            }

            Section {
                Toggle("Write the title and properties of quick-added tasks", isOn: $autoClassify)
                    .onChange(of: autoClassify) { _, newValue in
                        appState.autoClassifiesQuickAddedTasks = newValue
                    }
            } header: {
                Text("Quick Add")
            } footer: {
                Text("Quick add keeps your text as the description. When enabled, the suggestions model writes a title and fills empty properties, including version and milestone.")
            }

            Section {
                LabeledContent("AI suggestions model") {
                    Menu {
                        Button("Default task agent") { selectSuggestionAgent(nil) }
                        Divider()
                        ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                            Section(section.title) {
                                ForEach(section.models, id: \.key) { model in
                                    Button(model.displayName) {
                                        selectSuggestionAgent(TaskAgentConfig(provider: model.provider, model: model.id))
                                    }
                                }
                            }
                        }
                    } label: {
                        TaskBoardChipLabel(
                            icon: "sparkles",
                            title: suggestionAgent.map(appState.taskAgentLabel) ?? String(localized: "Default task agent"),
                            isActive: suggestionAgent != nil
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            } header: {
                Text("AI Suggestions")
            } footer: {
                Text("This model powers quick add and the task and story forms' title and Auto-fill buttons. ACP client suggestions run in a separate session.")
            }

            notionSection
        }
        .formStyle(.grouped)
        .onAppear {
            configured = appState.configuredDefaultTaskAgent()
            suggestionAgent = appState.configuredTaskSuggestionAgent()
            autoClassify = appState.autoClassifiesQuickAddedTasks
        }
    }

    private var notionSection: some View {
        Section {
            NotionConnectionView()
        } header: {
            Text("Notion")
        } footer: {
            Text("Used to sync project task status to a Notion database and import its pages as tasks. Connect with Notion signs in through the chosen relay server — one from Settings → Mobile or a hosted relay — which must have Notion sign-in configured. The token is stored in the Keychain.")
        }
    }

    private var agentTitle: String {
        guard let configured else {
            return String(localized: "Last used (\(appState.taskAgentLabel(appState.defaultTaskAgent())))")
        }
        return appState.taskAgentLabel(configured)
    }

    private func select(_ agent: TaskAgentConfig?) {
        appState.setConfiguredDefaultTaskAgent(provider: agent?.provider, model: agent?.model)
        configured = appState.configuredDefaultTaskAgent()
    }

    private func selectSuggestionAgent(_ agent: TaskAgentConfig?) {
        appState.setConfiguredTaskSuggestionAgent(agent)
        suggestionAgent = agent
    }
}
