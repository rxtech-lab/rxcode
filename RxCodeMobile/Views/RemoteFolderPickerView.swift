import SwiftUI
import RxCodeCore
import RxCodeSync

/// Browses the paired Mac's folder tree. Reused for three jobs: adding a new
/// project, picking an arbitrary folder (e.g. a run profile working
/// directory), and picking an entry such as an `.xcodeproj` bundle or a
/// Makefile. The chosen value is handed back to the caller.
struct RemoteFolderPickerView: View {
    /// Describes a "pick an entry" job — a file or bundle the user taps to
    /// select, rather than navigating into.
    struct EntryPick {
        let title: LocalizedStringResource
        let startPath: String?
        /// Ask the desktop to include plain files in the tree.
        let includeFiles: Bool
        /// `true` for child nodes that are the pick target — tapping one
        /// selects it instead of navigating into it.
        let isTarget: (RemoteFolderNode) -> Bool
        let onSelect: (String) -> Void
    }

    /// What the picker does with the entry the user confirms.
    enum Mode {
        /// Adds the chosen folder as a new project (original behavior).
        case addProject
        /// Hands the chosen folder path back to the caller. `startPath` is where
        /// browsing begins (`nil` = the picker roots).
        case pickFolder(title: LocalizedStringResource, startPath: String?, onSelect: (String) -> Void)
        /// Hands back a file or bundle the user taps in the tree.
        case pickEntry(EntryPick)
    }

    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath: [FolderLocation] = []
    /// Set after a project is created (addProject mode) when it has a linked
    /// GitHub repo — presents the first-add secrets download form. Dismissing
    /// that form closes the picker.
    @State private var firstAddProject: Project?

    var mode: Mode = .addProject

    private var currentNode: RemoteFolderNode? {
        state.remoteFolderRoot
    }

    private var isPickFolder: Bool {
        if case .pickFolder = mode { return true }
        return false
    }

    private var entryPick: EntryPick? {
        if case .pickEntry(let pick) = mode { return pick }
        return nil
    }

    private var navigationTitle: LocalizedStringResource {
        switch mode {
        case .addProject: return "Add Project"
        case .pickFolder(let title, _, _): return title
        case .pickEntry(let pick): return pick.title
        }
    }

    private var startPath: String? {
        switch mode {
        case .addProject: return nil
        case .pickFolder(_, let startPath, _): return startPath
        case .pickEntry(let pick): return pick.startPath
        }
    }

    private var includeFiles: Bool {
        entryPick?.includeFiles ?? false
    }

    /// `true` while browsing for a single folder result (working directory) or
    /// a project — the toolbar carries a "confirm current folder" button.
    private var hasConfirmButton: Bool {
        entryPick == nil
    }

    private var canConfirmCurrentFolder: Bool {
        guard let currentNode, !currentNode.path.isEmpty else { return false }
        // Any folder is a valid working directory; project creation keeps the
        // desktop's `isSelectable` gate.
        return isPickFolder ? true : currentNode.isSelectable
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            folderList
                .navigationDestination(for: FolderLocation.self) { _ in
                    folderList
                }
        }
        .task {
            if entryPick != nil || isPickFolder {
                await state.requestRemoteFolder(path: startPath, includeFiles: includeFiles)
            } else if state.remoteFolderRoot == nil {
                await state.requestRemoteFolder()
            }
        }
        .onChange(of: navigationPath) { _, newValue in
            Task {
                await state.requestRemoteFolder(path: newValue.last?.path, includeFiles: includeFiles)
            }
        }
        .alert("Unable to Load Folder", isPresented: folderErrorBinding) {
            Button("OK", role: .cancel) { state.remoteFolderError = nil }
        } message: {
            Text(state.remoteFolderError ?? String(localized: "Unknown error."))
        }
        .alert("Unable to Add Project", isPresented: createErrorBinding) {
            Button("OK", role: .cancel) { state.remoteProjectCreateError = nil }
        } message: {
            Text(state.remoteProjectCreateError ?? String(localized: "Unknown error."))
        }
        .onChange(of: state.lastCreatedProjectID) { _, newValue in
            guard case .addProject = mode, let newValue else { return }
            // Mirror the desktop's on-repository-add secrets flow: if the new
            // project is repo-backed, offer to download its secrets (loading
            // overlay → environment picker) before closing. Otherwise just close.
            if let created = state.projects.first(where: { $0.id == newValue }),
               created.gitHubRepo != nil {
                firstAddProject = created
            } else {
                dismiss()
            }
        }
        .sheet(item: $firstAddProject, onDismiss: { dismiss() }) { project in
            ProjectSecretsDownloadSheet(project: project, autoDismissWhenEmpty: true)
                .environmentObject(state)
                .mobileSheetPresentation()
        }
    }

    private var folderList: some View {
        List {
            if let currentNode {
                Section {
                    currentFolderRow(currentNode)
                }

                Section {
                    if currentNode.children.isEmpty, !state.remoteFolderIsLoading {
                        emptyFolderView
                    } else {
                        ForEach(currentNode.children) { child in
                            childRow(child)
                        }
                    }
                } header: {
                    Text(contentsSectionTitle)
                }
            } else if state.remoteFolderIsLoading {
                loadingRow
            } else {
                ContentUnavailableView(
                    "Folders Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(state.remoteFolderError ?? String(localized: "Connect to your Mac and try again."))
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if state.remoteFolderIsLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if hasConfirmButton {
                    Button {
                        confirmCurrentFolder()
                    } label: {
                        Image(systemName: isPickFolder ? "checkmark" : "plus")
                    }
                    .accessibilityLabel(Text(confirmButtonAccessibilityLabel))
                    .disabled(!canConfirmCurrentFolder || state.remoteProjectCreateInFlight)
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }

            ToolbarItem(placement: .bottomBar) {
                if hasConfirmButton, state.remoteProjectCreateInFlight {
                    ProgressView()
                }
            }
        }
    }

    private var contentsSectionTitle: LocalizedStringResource {
        includeFiles ? "Contents" : "Folders"
    }

    private var confirmButtonAccessibilityLabel: LocalizedStringResource {
        isPickFolder ? "Select Folder" : "Add Project"
    }

    @ViewBuilder
    private var emptyFolderView: some View {
        if includeFiles {
            ContentUnavailableView(
                "Empty Folder",
                systemImage: "folder",
                description: Text("This location has nothing to show.")
            )
            .listRowBackground(Color.clear)
        } else {
            ContentUnavailableView(
                "No Folders",
                systemImage: "folder",
                description: Text("This location has no visible folders.")
            )
            .listRowBackground(Color.clear)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading folders")
                .foregroundStyle(.secondary)
        }
    }

    /// Renders one child node: a selectable entry (file / bundle), a navigable
    /// folder, or — rarely — a non-target file shown dimmed.
    @ViewBuilder
    private func childRow(_ child: RemoteFolderNode) -> some View {
        if let entryPick, entryPick.isTarget(child) {
            Button {
                entryPick.onSelect(child.path)
                dismiss()
            } label: {
                entryTargetRow(child)
            }
            .buttonStyle(.plain)
            .disabled(state.remoteFolderIsLoading)
        } else if child.isDirectory {
            Button {
                open(child)
            } label: {
                folderRow(child)
            }
            .buttonStyle(.plain)
            .disabled(state.remoteFolderIsLoading)
        } else {
            fileRow(child)
        }
    }

    private func currentFolderRow(_ node: RemoteFolderNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(node.name, systemImage: node.path.isEmpty ? "macbook" : "folder.fill")
                .font(.headline)

            if !node.path.isEmpty {
                Text(node.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func folderRow(_ node: RemoteFolderNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(node.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// A tappable file / bundle the caller is picking.
    private func entryTargetRow(_ node: RemoteFolderNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entryIcon(node))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(node.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }

    /// A non-target file — shown dimmed so the list stays readable.
    private func fileRow(_ node: RemoteFolderNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(.tertiary)
            Text(node.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func entryIcon(_ node: RemoteFolderNode) -> String {
        if node.name.hasSuffix(".xcodeproj") || node.name.hasSuffix(".xcworkspace") {
            return "hammer.fill"
        }
        return node.isDirectory ? "folder.fill" : "doc.text.fill"
    }

    private var folderErrorBinding: Binding<Bool> {
        Binding(
            get: { state.remoteFolderError != nil },
            set: { if !$0 { state.remoteFolderError = nil } }
        )
    }

    private var createErrorBinding: Binding<Bool> {
        Binding(
            get: { state.remoteProjectCreateError != nil },
            set: { if !$0 { state.remoteProjectCreateError = nil } }
        )
    }

    private func open(_ node: RemoteFolderNode) {
        navigationPath = folderNavigationPath(for: node.path)
    }

    private func confirmCurrentFolder() {
        guard let currentNode, canConfirmCurrentFolder else { return }
        switch mode {
        case .addProject:
            Task { await state.createProjectFromRemoteFolder(path: currentNode.path) }
        case .pickFolder(_, _, let onSelect):
            onSelect(currentNode.path)
            dismiss()
        case .pickEntry:
            break
        }
    }

    private func folderNavigationPath(for path: String) -> [FolderLocation] {
        var locations: [FolderLocation] = []
        var url = URL(fileURLWithPath: path).standardizedFileURL

        while true {
            locations.append(FolderLocation(path: url.path))

            let parent = url.deletingLastPathComponent().standardizedFileURL
            guard parent.path != url.path else { break }
            url = parent
        }

        return locations.reversed()
    }
}

private struct FolderLocation: Hashable {
    let path: String
}
