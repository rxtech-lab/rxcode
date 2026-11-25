import RxCodeCore
import SwiftUI

struct ChangesView: View {
    var body: some View {
        RepositoryContent { tree in
            WorkingTreeChanges(tree: tree)
                .id(tree.head)
        }
    }
}

private struct WorkingTreeChanges: View {
    let tree: GitWorkingTree
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(RepositoryStatus.self) private var repository

    private enum Scope: CaseIterable {
        case unstaged, staged, thread

        var title: LocalizedStringResource {
            switch self {
            case .unstaged: "Unstaged"
            case .staged: "Staged"
            case .thread: "This Thread"
            }
        }
    }

    @State private var scope: Scope
    @State private var threadChanges: (sessionId: String, files: [FileEditSummary])?
    @State private var selection = Set<String>()
    @State private var showsCommit = false
    @State private var draft = ""
    @State private var operation: LocalizedStringResource?
    @State private var error: String?

    init(tree: GitWorkingTree) {
        self.tree = tree
        _scope = State(initialValue: tree.changes.unstaged.isEmpty && !tree.changes.staged.isEmpty ? .staged : .unstaged)
    }

    private var threadLoadID: ThreadFileEditsLoadID {
        appState.threadFileEditsLoadID(sessionId: windowState.currentSessionId ?? windowState.newSessionKey)
    }

    private var threadFiles: [FileEditSummary]? {
        threadChanges?.sessionId == threadLoadID.sessionId ? threadChanges?.files : nil
    }

    private var showsStaged: Bool { scope == .staged }
    private var files: [GitChangeFile] { showsStaged ? tree.changes.staged : tree.changes.unstaged }
    private var clean: Bool { tree.changes.unstaged.isEmpty && tree.changes.staged.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(ClaudeTheme.accent)
                Text(tree.isDetached ? String(localized: "Detached at \(tree.head)") : tree.head)
                    .font(.headline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    openWindow(id: "git-window", value: GitWindowValue(
                        path: repository.path ?? tree.root,
                        workspaceID: appState.activeWorkspace.id,
                        projectID: windowState.selectedProject?.id
                    ))
                } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(.borderless)
                .help("Open Git history, branches, and rebase tools")
                .accessibilityLabel("Open Git Window")
                Button {
                    if let path = repository.path { Task { await repository.refresh(at: path) } }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh changes")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            HStack(spacing: 0) {
                WorkspaceUnderlineTabPicker(options: Scope.allCases, selection: $scope) { tab, selected in
                    WorkspaceUnderlineTabLabel(
                        title: tab.title,
                        count: fileCount(for: tab),
                        isSelected: selected
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .background(alignment: .bottom) { ClaudeThemeDivider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Change list")
            .onChange(of: scope) { selection.removeAll() }

            if scope == .thread {
                ThreadChangeList(summaries: threadFiles, showDiff: { file in
                    windowState.diffFile = PreviewFile(
                        path: file.path, name: file.name, editHunks: file.hunks,
                        showFullFileDiff: true, originalContent: file.originalContent,
                        modifiedContent: file.modifiedContent, preferHunks: file.hasExternalInterleaving
                    )
                }, showPreview: { file in
                    windowState.inspectorFile = PreviewFile(path: file.path, name: file.name)
                })
            } else if files.isEmpty {
                ContentUnavailableView {
                    if clean {
                        Label("Working tree clean", systemImage: "checkmark.circle")
                    } else if showsStaged {
                        Label("No staged changes", systemImage: "tray")
                    } else {
                        Label("No unstaged changes", systemImage: "checkmark.circle")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
                HStack {
                    Button("Show Diff") { showDiff(selection) }
                        .disabled(selection.count != 1)
                    Spacer()
                    Button(showsStaged ? "Unstage Selected" : "Stage Selected") { changeStage() }
                        .disabled(selection.isEmpty)
                }
                .controlSize(.small)
                .padding(10)
            }

            if scope != .thread {
                ClaudeThemeDivider()
                HStack(spacing: 6) {
                    syncStatus
                    Spacer(minLength: 0)
                    if let tracking = tree.upstream, !tracking.remotes.isEmpty || tracking.upstream != nil {
                        Button(tracking.upstream == nil ? "Publish" : "Push") { push(tracking) }
                            .disabled(tracking.upstream != nil && tracking.ahead == 0)
                            .help(tracking.upstream ?? String(localized: "Publish this branch to its remote"))
                    }
                    Button("Commit…") { showsCommit = true }
                        .buttonStyle(.borderedProminent)
                        .tint(ClaudeTheme.accent)
                        .disabled(tree.changes.staged.isEmpty)
                }
                .controlSize(.small)
                .padding(10)
            }
        }
        .disabled(operation != nil)
        .overlay { GitOperationOverlay(operation: operation) }
        .task { ExternalEditorService.shared.detectIfNeeded() }
        .task(id: threadLoadID) { [key = threadLoadID] in
            let summaries = await appState.loadThreadDiffPreview(key)
            guard !Task.isCancelled, threadLoadID == key else { return }
            threadChanges = (key.sessionId, summaries)
        }
        .onChange(of: files) {
            selection.formIntersection(files.map(\.displayPath))
        }
        .sheet(isPresented: $showsCommit) {
            GitCommitSheet(tree: tree, message: $draft)
        }
        .alert("Git operation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear {
            AnalyticsService.shared.log(.diffViewOpened, parameters: [
                "project_id": windowState.selectedProject?.id.uuidString ?? "",
                "surface": "inspector_changes",
            ])
        }
    }

    private func fileCount(for tab: Scope) -> Int? {
        switch tab {
        case .unstaged: tree.changes.unstaged.count
        case .staged: tree.changes.staged.count
        case .thread: threadFiles?.count
        }
    }

    private var fileList: some View {
        List(files, selection: $selection) { file in
            ChangeFileRow(file: file)
                .listRowSeparatorTint(ClaudeTheme.divider)
                .tag(file.displayPath)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { paths in
            let selectedFiles = files.filter { paths.contains($0.displayPath) }
            if selectedFiles.count == 1, let file = selectedFiles.first {
                Button("Show Diff", systemImage: "arrow.left.arrow.right") { showDiff(paths) }
                Button("Show Preview", systemImage: "eye") { showPreview(paths) }
                    .disabled(file.statusChar == "D" || !FileManager.default.fileExists(atPath: file.path))
                Divider()
            }
            if !selectedFiles.isEmpty {
                GitFileSystemContextMenuItems(paths: selectedFiles.map(\.path))
            }
        } primaryAction: { paths in showDiff(paths) }
    }

    private func showDiff(_ paths: Set<String>) {
        guard paths.count == 1, let file = files.first(where: { paths.contains($0.displayPath) }) else { return }
        windowState.diffFile = PreviewFile(path: file.path, name: file.name, gitDiffMode: file.diffMode)
    }

    private func showPreview(_ paths: Set<String>) {
        guard paths.count == 1, let file = files.first(where: { paths.contains($0.displayPath) }) else { return }
        windowState.inspectorFile = PreviewFile(path: file.path, name: file.name)
    }

    @ViewBuilder private var syncStatus: some View {
        if let tracking = tree.upstream {
            Group {
                if tracking.upstream == nil {
                    Text(tracking.remotes.isEmpty ? "Local only" : "No upstream")
                } else if tracking.ahead == 0 && tracking.behind == 0 {
                    Label("Up to date", systemImage: "checkmark.icloud")
                } else {
                    HStack(spacing: 5) {
                        if tracking.ahead > 0 { Label("\(tracking.ahead)", systemImage: "arrow.up") }
                        if tracking.behind > 0 { Label("\(tracking.behind)", systemImage: "arrow.down") }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(tracking.upstream ?? String(localized: "No upstream branch configured"))
        }
    }

    private func changeStage() {
        let paths = files.filter { selection.contains($0.displayPath) }.flatMap(\.pathspecs)
        guard !paths.isEmpty else { return }
        let unstage = showsStaged
        perform(unstage ? "Unstaging files…" : "Staging files…") {
            if unstage { return await GitHelper.unstage(paths: paths, at: tree.root) }
            return await GitHelper.stage(paths: paths, at: tree.root)
        }
    }

    private func push(_ tracking: GitHelper.UpstreamStatus) {
        perform(tracking.upstream == nil ? "Publishing branch…" : "Pushing commits…") {
            if tracking.upstream != nil {
                let ref = "refs/heads/\(tracking.branch)"
                let format = "--format=%(upstream:remotename)%00%(upstream:remoteref)"
                let target = await GitHelper.run(["for-each-ref", format, ref], at: tree.root)?
                    .trimmingCharacters(in: .newlines).split(separator: "\0")
                guard let target, target.count == 2 else { return String(localized: "The upstream branch is unavailable.") }
                return await GitHelper.runWithError(["push", "--", String(target[0]), "\(ref):\(target[1])"], at: tree.root)
            }
            guard let remote = tracking.remotes.contains("origin") ? "origin" : tracking.remotes.first else { return nil }
            return await GitHelper.push(at: tree.root, remote: remote, branch: tracking.branch, setUpstream: true)
        }
    }

    private func perform(_ label: LocalizedStringResource, action: @escaping () async -> String?) {
        guard operation == nil, let path = repository.path else { return }
        operation = label
        Task {
            error = await action()
            await repository.refresh(at: path)
            operation = nil
        }
    }
}

struct GitOperationOverlay: View {
    let operation: LocalizedStringResource?

    var body: some View {
        if let operation {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(operation)
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
        }
    }
}
