import RxCodeCore
import SwiftUI

struct TaskThinkingLevelPicker: View {
    let levels: [ReasoningLevel]
    let defaultTitle: String
    @Binding var effort: String?

    var body: some View {
        Picker("Thinking Level", selection: $effort) {
            Text(defaultTitle).tag(String?.none)
            ForEach(levels) { level in
                Text(level.displayName).tag(Optional(level.id))
            }
        }
    }
}

struct TaskThinkingLevelSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let task: ProjectTask
    let onSave: () -> Void

    @State private var effort: String?
    @State private var showsUpdateError = false

    var body: some View {
        let selection = appState.taskModelSelection(for: task)
        let levels = appState.reasoningLevels(for: selection.provider, model: selection.model)
        NavigationStack {
            Form {
                Section {
                    TaskThinkingLevelPicker(
                        levels: levels,
                        defaultTitle: appState.defaultEffortTitle(for: selection.provider, model: selection.model),
                        effort: $effort
                    )
                    .pickerStyle(.radioGroup)
                    .foregroundStyle(ClaudeTheme.textPrimary, ClaudeTheme.textSecondary, ClaudeTheme.textTertiary)
                    .labelsHidden()
                } header: {
                    Text(appState.modelDisplayLabel(selection.model, provider: selection.provider))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Thinking Level")
            .navigationSubtitle(task.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard appState.updateTaskEffort(effort, for: task) else {
                            showsUpdateError = true
                            return
                        }
                        onSave()
                        dismiss()
                    }
                    .disabled(effort == task.agent.effort)
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 300, idealHeight: 360)
        .onAppear { effort = levels.first { $0.id == task.agent.effort }?.id }
        .alert("Couldn’t Update Thinking Level", isPresented: $showsUpdateError) {
            Button("OK") { dismiss() }
        } message: {
            Text("The task or its available levels changed. Reopen the picker to try again.")
        }
    }
}
