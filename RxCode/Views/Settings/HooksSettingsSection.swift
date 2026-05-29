import RxCodeCore
import SwiftUI

/// "Hooks" section embedded in the General settings tab. Hooks are per-project,
/// so this offers a project picker and opens the split-pane editor as a sheet.
struct HooksSettingsSection: View {
    @Environment(AppState.self) private var appState

    @State private var selectedProjectId: UUID?
    @State private var showEditor = false

    private var selectedProject: Project? {
        guard let id = selectedProjectId else { return appState.projects.first }
        return appState.projects.first { $0.id == id } ?? appState.projects.first
    }

    private var hookCount: Int {
        guard let project = selectedProject else { return 0 }
        return appState.hookProfiles(for: project.id).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hooks")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Run commands automatically at session lifecycle points. Hooks are configured per project.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.projects.isEmpty {
                Text("Add a project to configure hooks.")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 10) {
                    Picker("Project", selection: Binding(
                        get: { selectedProject?.id },
                        set: { selectedProjectId = $0 }
                    )) {
                        ForEach(appState.projects) { project in
                            Text(project.name).tag(UUID?.some(project.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)

                    Spacer(minLength: 0)

                    if hookCount > 0 {
                        Text("^[\(hookCount) hook](inflect: true)")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button("Manage Hooks…") {
                        showEditor = true
                    }
                    .disabled(selectedProject == nil)
                }
            }
        }
        .task(id: selectedProject?.id) {
            if let project = selectedProject {
                await appState.ensureHookProfilesLoaded(for: project.id)
            }
        }
        .sheet(isPresented: $showEditor) {
            if let project = selectedProject {
                HookConfigurationsView(project: project)
                    .environment(appState)
            }
        }
    }
}
