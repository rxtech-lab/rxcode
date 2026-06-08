import RxCodeCore
import SwiftUI

struct WorkspaceSwitcher: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Binding var showingCreateSheet: Bool
    @Binding var showingManageSheet: Bool

    var body: some View {
        Menu {
            ForEach(appState.workspaces) { workspace in
                Button {
                    switchTo(workspace)
                } label: {
                    if workspace.id == appState.activeWorkspace.id {
                        Label(workspace.name, systemImage: "checkmark")
                    } else {
                        Text(workspace.name)
                    }
                }
                .disabled(workspace.id == appState.activeWorkspace.id)
            }

            Divider()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create Workspace...", systemImage: "plus")
            }

            Button {
                showingManageSheet = true
            } label: {
                Label("Manage Workspaces...", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                Text(appState.activeWorkspace.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: ClaudeTheme.size(9), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
            .frame(maxWidth: 180)
        }
        .help("Switch Workspace")
    }

    /// Switching to another workspace opens (or refocuses) that workspace's own
    /// window, leaving the current window untouched. The registry's active
    /// workspace is updated so the next launch restores the same one.
    private func switchTo(_ workspace: AppWorkspace) {
        guard workspace.id != appState.activeWorkspace.id else { return }
        appState.activateWorkspace(id: workspace.id)
        openWindow(id: "workspace-window", value: WorkspaceWindowValue(workspaceID: workspace.id))
    }
}

struct CreateWorkspaceSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Workspace")
                .font(.system(size: ClaudeTheme.size(16), weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let workspace = appState.createWorkspace(named: trimmed)
        appState.activateWorkspace(id: workspace.id)
        openWindow(id: "workspace-window", value: WorkspaceWindowValue(workspaceID: workspace.id))
        dismiss()
    }
}

struct ManageWorkspacesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceManager.self) private var workspaceManager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss

    @State private var editingID: String?
    @State private var editingName: String = ""
    @State private var deleteCandidate: AppWorkspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Workspaces")
                .font(.system(size: ClaudeTheme.size(16), weight: .semibold))

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(appState.workspaces) { workspace in
                        row(workspace)
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let workspace = deleteCandidate {
                    delete(workspace)
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes the workspace and its settings. Files on disk are not deleted.")
        }
    }

    @ViewBuilder
    private func row(_ workspace: AppWorkspace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            if editingID == workspace.id {
                TextField("Workspace name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(workspace) }
                Button("Save") { commitRename(workspace) }
                    .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editingID = nil }
            } else {
                Text(workspace.name)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .lineLimit(1)

                if workspace.id == appState.activeWorkspace.id {
                    Text("Active")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if workspace.isPersonal {
                    Text("Default")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        startRename(workspace)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename Workspace")

                    Button {
                        deleteCandidate = workspace
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete Workspace")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func startRename(_ workspace: AppWorkspace) {
        editingID = workspace.id
        editingName = workspace.name
    }

    private func commitRename(_ workspace: AppWorkspace) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.renameWorkspace(id: workspace.id, to: trimmed)
        editingID = nil
    }

    /// Remove the workspace from the registry, then close its window (if open)
    /// and drop its cached AppState so its services tear down.
    private func delete(_ workspace: AppWorkspace) {
        guard appState.deleteWorkspace(id: workspace.id) else { return }
        dismissWindow(id: "workspace-window", value: WorkspaceWindowValue(workspaceID: workspace.id))
        workspaceManager.discard(workspace.id)
    }
}
