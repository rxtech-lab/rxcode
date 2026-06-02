import SwiftUI
import RxCodeCore
import UniformTypeIdentifiers

struct ProjectListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showFilePicker = false
    @State private var projectToDelete: Project? = nil
    @State private var projectToRename: Project? = nil
    @State private var renameText: String = ""
    @State private var creatingPRProjectId: UUID? = nil
    @State private var prError: PRErrorAlert? = nil

    private struct PRErrorAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    /// Mirror the briefing card's gate: offer "Create PR" only for a
    /// GitHub-linked project whose current branch has no PR yet.
    private func canCreatePR(_ project: Project) -> Bool {
        guard project.gitHubRepo != nil else { return false }
        let _ = appState.ciStatusRevision
        return appState.ciStatusByProject[project.id]?.pullRequestState == nil
    }

    /// Push the current branch and open a PR for it, then reveal it in the browser.
    private func startCreatePR(_ project: Project) {
        guard creatingPRProjectId == nil else { return }
        creatingPRProjectId = project.id
        Task { @MainActor in
            defer { creatingPRProjectId = nil }
            do {
                let url = try await appState.createPullRequestForCurrentBranch(project: project)
                NSWorkspace.shared.open(url)
            } catch {
                prError = PRErrorAlert(message: error.localizedDescription)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            List(appState.projects, selection: selectedProjectBinding) { project in
                projectRow(project)
                    .tag(project.id)
                    .contextMenu {
                        if canCreatePR(project) {
                            Button { startCreatePR(project) } label: {
                                Label(
                                    creatingPRProjectId == project.id ? "Creating Pull Request…" : "Create Pull Request",
                                    systemImage: "arrow.triangle.pull"
                                )
                            }
                            .disabled(creatingPRProjectId == project.id)
                            Divider()
                        }
                        let hookItems = appState.projectContextMenuItems(for: project)
                        if !hookItems.isEmpty {
                            HookContextMenuItems(items: hookItems)
                            Divider()
                        }
                        Button {
                            renameText = project.name
                            projectToRename = project
                        } label: {
                            Label("Rename Project", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("Delete Project", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.sidebar)
            .confirmationDialog(
                "Delete \"\(projectToDelete?.name ?? "")\"?",
                isPresented: Binding(
                    get: { projectToDelete != nil },
                    set: { if !$0 { projectToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let project = projectToDelete {
                        Task { await appState.deleteProject(project, in: windowState) }
                    }
                    projectToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    projectToDelete = nil
                }
            } message: {
                Text("This will remove the project from RxCode. The files on disk will not be deleted.")
            }
            .sheet(item: $projectToRename) { project in
                RenameProjectSheet(name: $renameText) {
                    Task { await appState.renameProject(project, to: renameText) }
                }
            }
            .alert(item: $prError) { error in
                Alert(
                    title: Text("Couldn't Create Pull Request"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Projects")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            Spacer()

            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add Project")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderSelection(result)
            }
        }
    }

    // MARK: - Project Row

    private func projectRow(_ project: Project) -> some View {
        let isSelected = windowState.selectedProject?.id == project.id

        return HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.body)
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                }

                Text(truncatedPath(project.path))
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var selectedProjectBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { windowState.selectedProject?.id },
            set: { id in
                if let id,
                   let project = appState.projects.first(where: { $0.id == id }) {
                    appState.selectProject(project, in: windowState)
                }
            }
        )
    }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    private func truncatedPath(_ path: String) -> String {
        if path.hasPrefix(Self.homePath) {
            return "~" + path.dropFirst(Self.homePath.count)
        }
        return path
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else { return }

        Task {
            await appState.addProjectFromFolder(url, in: windowState)
        }
    }
}

// MARK: - Rename Sheet

struct RenameProjectSheet: View {
    @Binding var name: String
    @Environment(\.dismiss) private var dismiss
    var onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Project")
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { confirm() }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Rename") { confirm() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    private func confirm() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConfirm()
        dismiss()
    }
}

#Preview {
    ProjectListView()
        .environment(AppState())
        .frame(width: 260)
}
