import RxCodeCore
import SwiftUI

/// "Tasks" tab in SettingsView: the agent new tasks are assigned to, and
/// whether quick-added tasks get their properties filled in by that agent.
struct TasksSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// Mirrors the persisted setting, which lives in workspace defaults and
    /// isn't observable on its own.
    @State private var configured: TaskAgentConfig?
    @State private var autoClassify = true

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                Stepper(value: $appState.taskCardRetentionDays, in: 1...365) {
                    LabeledContent("Hide done items after") {
                        Text(appState.taskCardRetentionDays == 1 ? "1 day" : "\(appState.taskCardRetentionDays) days")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Project Dashboard")
            } footer: {
                Text("Cards in done columns and finished stories with no updates for this long are hidden from the board. Open work is never hidden. Reveal older items 10 at a time.")
            }

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
                Text("Quick add keeps your text as the description. When enabled, the general AI model (Settings → Message) writes a title and fills empty properties, including version and milestone.")
            }

        }
        .formStyle(.grouped)
        .onAppear {
            configured = appState.configuredDefaultTaskAgent()
            autoClassify = appState.autoClassifiesQuickAddedTasks
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
}
