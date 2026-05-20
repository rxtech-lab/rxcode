import SwiftUI
import RxCodeSync

struct RemoteFolderPickerView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath: [FolderLocation] = []

    private var currentNode: RemoteFolderNode? {
        state.remoteFolderRoot
    }

    private var canAddCurrentFolder: Bool {
        guard let currentNode else { return false }
        return currentNode.isSelectable && !currentNode.path.isEmpty
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            folderList
                .navigationDestination(for: FolderLocation.self) { _ in
                    folderList
                }
        }
        .task {
            if state.remoteFolderRoot == nil {
                await state.requestRemoteFolder()
            }
        }
        .onChange(of: navigationPath) { _, newValue in
            Task { await state.requestRemoteFolder(path: newValue.last?.path) }
        }
        .alert("Unable to Load Folder", isPresented: folderErrorBinding) {
            Button("OK", role: .cancel) { state.remoteFolderError = nil }
        } message: {
            Text(state.remoteFolderError ?? "Unknown error.")
        }
        .alert("Unable to Add Project", isPresented: createErrorBinding) {
            Button("OK", role: .cancel) { state.remoteProjectCreateError = nil }
        } message: {
            Text(state.remoteProjectCreateError ?? "Unknown error.")
        }
        .onChange(of: state.lastCreatedProjectID) { _, newValue in
            if newValue != nil {
                dismiss()
            }
        }
    }

    private var folderList: some View {
        List {
            if let currentNode {
                Section {
                    currentFolderRow(currentNode)
                }

                Section("Folders") {
                    if currentNode.children.isEmpty, !state.remoteFolderIsLoading {
                        ContentUnavailableView(
                            "No Folders",
                            systemImage: "folder",
                            description: Text("This location has no visible folders.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(currentNode.children) { child in
                            Button {
                                open(child)
                            } label: {
                                folderRow(child)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.remoteFolderIsLoading)
                        }
                    }
                }
            } else if state.remoteFolderIsLoading {
                loadingRow
            } else {
                ContentUnavailableView(
                    "Folders Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(state.remoteFolderError ?? "Connect to your Mac and try again.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Add Project")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if state.remoteFolderIsLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    addCurrentFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Project")
                .disabled(!canAddCurrentFolder || state.remoteProjectCreateInFlight)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }

            ToolbarItem(placement: .bottomBar) {
                if state.remoteProjectCreateInFlight {
                    ProgressView()
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading folders")
                .foregroundStyle(.secondary)
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

    private func addCurrentFolder() {
        guard let currentNode, canAddCurrentFolder else { return }
        Task { await state.createProjectFromRemoteFolder(path: currentNode.path) }
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
