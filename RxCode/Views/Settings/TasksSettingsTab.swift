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
                Toggle("Auto-fill properties for quick-added tasks", isOn: $autoClassify)
                    .onChange(of: autoClassify) { _, newValue in
                        appState.autoClassifiesQuickAddedTasks = newValue
                    }
            } header: {
                Text("Quick Add")
            } footer: {
                Text("When you add a task by title only, the default agent fills in its type, priority, tags, version and milestone. Properties you or the story already set are kept. ACP agents fall back to Claude Haiku.")
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
