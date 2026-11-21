import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

struct AgentPromptsSettingsSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage("globalAgentPrompt") private var globalPrompt = ""
    @State private var showProjectPrompts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Prompts")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("These instructions are included with every agent turn. Project instructions are added after the global instructions.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Global prompt")
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            promptEditor(text: $globalPrompt, label: "Global prompt")

            HStack {
                Text("Project prompts")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                Spacer()
                Button("Manage Project Prompts…") {
                    showProjectPrompts = true
                }
            }
        }
        .sheet(isPresented: $showProjectPrompts) {
            ProjectPromptsSheet()
                .environment(appState)
        }
    }

    private func promptEditor(text: Binding<String>, label: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: ClaudeTheme.size(12)))
            .frame(height: 88)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(label)
    }
}

private struct ProjectPromptsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if appState.projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder",
                        description: Text("Add a project to configure its prompt.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(appState.projects) { project in
                        NavigationLink(value: project.id) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundStyle(ClaudeTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .navigationDestination(for: UUID.self) { projectId in
                        ProjectPromptDetailPage(projectId: projectId) { dismiss() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Project Prompts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 600, height: 480)
    }
}

private struct ProjectPromptDetailPage: View {
    @Environment(AppState.self) private var appState
    let projectId: UUID
    let closeSheet: () -> Void

    private var project: Project? {
        appState.projects.first { $0.id == projectId }
    }

    var body: some View {
        Group {
            if let project {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Project prompt")
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    Text("These instructions are included with every agent turn in this project, after the global prompt.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    TextEditor(text: Binding(
                        get: { appState.projects.first(where: { $0.id == projectId })?.customPrompt ?? "" },
                        set: { appState.setProjectPrompt($0, for: projectId) }
                    ))
                    .font(.system(size: ClaudeTheme.size(12)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Project prompt")
                }
                .padding(20)
                .navigationTitle(project.name)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: closeSheet)
                    }
                }
            } else {
                ContentUnavailableView("Project Unavailable", systemImage: "folder.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
