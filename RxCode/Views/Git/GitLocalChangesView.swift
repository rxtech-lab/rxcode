import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Working tree changes: stage, unstage, discard, stash, and commit.
struct GitLocalChangesView: View {
    let store: GitWorkflowStore
    @Environment(RepositoryStatus.self) private var repository
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = Set<String>()
    @State private var amend = false
    @State private var amendDraft: GitAmendDraft?
    @State private var flight: GitFileFlight?

    var body: some View {
        if case .ready(let tree) = repository.state, let lists = tree.changes.trees {
            content(tree, lists: lists)
        } else if case .loading = repository.state {
            ProgressView("Checking repository…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Repository unavailable", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private nonisolated static func tag(_ file: GitChangeFile) -> String {
        (file.diffMode == .staged ? "s:" : "u:") + file.displayPath
    }

    private nonisolated static func tag(_ file: GitCommitFile) -> String { "c:" + file.path }

    private func content(_ tree: GitWorkingTree, lists: GitChangesSnapshot.Trees) -> some View {
        let unstaged = tree.changes.unstaged
        let staged = tree.changes.staged
        let all = unstaged + staged
        let selected = all.filter { selection.contains(Self.tag($0)) }
        let discardable = lists.unstaged.selectedFiles(in: selection, prefix: "u:")
        let amendableHead = store.snapshot.pendingOperation == nil ? tree.headCommit : nil
        let amendHead = amend ? amendableHead : nil
        let draft = amendHead == amendDraft?.commit.id && tree.upstream?.branch == amendDraft?.branch ? amendDraft : nil
        let originalFiles = draft?.files ?? []
        let tags = lists.unstaged.tags(prefix: "u:").union(lists.staged.tags(prefix: "s:")).union(draft?.changes.tags(prefix: "c:") ?? [])
        return VStack(spacing: 0) {
            if all.isEmpty && amendHead == nil {
                ContentUnavailableView("Working tree clean", systemImage: "checkmark.circle",
                                       description: Text("There are no uncommitted changes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VSplitView {
                        changesPane(lists.unstaged, staged: false) { move($0, toStaged: true, tree: tree) }
                            .frame(minHeight: 100, idealHeight: 330, maxHeight: .infinity)
                        changesPane(lists.staged, staged: true, original: draft?.changes) { move($0, toStaged: false, tree: tree) }
                            .frame(minHeight: 100, idealHeight: 240, maxHeight: .infinity)
                            .overlay { GitOperationOverlay(operation: amendHead != nil && draft == nil ? "Loading commit files…" : nil) }
                    }
                    .frame(minWidth: 190, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
                    .overlayPreferenceValue(GitTransferAnchors.self) { anchors in
                        if let flight, !reduceMotion {
                            GitFileTransferOverlay(flight: flight, anchors: anchors) {
                                captured(flight)
                            } onFinish: {
                                guard self.flight?.id == flight.id else { return }
                                withAnimation(.easeOut(duration: 0.15)) { self.flight = nil }
                            }
                            .id(flight.id)
                            .transition(.opacity)
                        }
                    }
                    // Give the split a stable size as the placeholder and file diffs change.
                    GeometryReader { _ in
                        if let folder = selectedFolder(lists, draft: draft) {
                            GitFolderContents(folder: folder.path, tree: folder.tree) { selection = [folder.prefix + $0] }
                        } else if selection.count == 1, let draft, let file = originalFiles.first(where: { selection.contains(Self.tag($0)) }) {
                            GitCommitFileDiffView(file: file, commit: draft.commit, root: tree.root)
                                .id("\(draft.commit.id):\(file.path)")
                        } else {
                            GitLocalChangeDiffView(file: selection.count == 1 ? selected.first : nil) {
                                selection.removeAll()
                            }
                        }
                    }
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            ClaudeThemeDivider()
            HStack(spacing: 8) {
                if !all.isEmpty {
                    Button("Discard…") { store.confirmation = .discard(discardable) }
                        .disabled(discardable.isEmpty)
                }
                Toggle("Amend", isOn: Binding(get: { amend }, set: { setAmend($0, originalFiles: originalFiles) }))
                    .toggleStyle(.checkbox)
                    .disabled(amendableHead == nil)
                    .help("Replace the latest commit using the current staged changes.")
                Spacer(minLength: 0)
                Button {
                    store.sheet = .commit(amend: draft)
                } label: {
                    Text(amendHead == nil ? "Commit…" : "Amend Commit…")
                        .contentTransition(.interpolate)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudeTheme.accent)
                .disabled(amendHead == nil ? staged.isEmpty : draft == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
            .padding(10)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: amendHead == nil)
        }
        .task(id: amendHead) {
            amendDraft = nil
            guard let amendHead else { return }
            let loaded = await GitAmendDraft.load(head: amendHead, branch: tree.upstream?.branch, at: tree.root)
            guard !Task.isCancelled else { return }
            if let loaded {
                amendDraft = loaded
                // The original commit's files drop out of the Amend checkbox into the staged list.
                if !reduceMotion, !loaded.files.isEmpty {
                    flight = GitFileFlight(source: nil, destination: .original, items: loaded.files.prefix(GitFileFlight.maxItems).map {
                        GitFlightItem(id: $0.path, label: .commit($0))
                    })
                }
            } else {
                amend = false
                store.error = String(localized: "Couldn’t load the commit to amend.")
            }
        }
        .onChange(of: tags) { selection.formIntersection(tags) }
        .onChange(of: amendableHead) { amend = false }
        .onChange(of: tree.head) { amend = false }
        .onChange(of: reduceMotion) { if reduceMotion { flight = nil } }
    }

    private func selectedFolder(_ lists: GitChangesSnapshot.Trees, draft: GitAmendDraft?) -> (prefix: String, path: String, tree: GitPathTree)? {
        guard selection.count == 1, let tag = selection.first else { return nil }
        let sections: [(String, GitPathTree?)] = [("u:", lists.unstaged.tree), ("s:", lists.staged.tree), ("c:", draft?.changes.tree)]
        for (prefix, tree) in sections where tag.hasPrefix(prefix) {
            let path = String(tag.dropFirst(prefix.count))
            if let tree, tree.folders.contains(path) { return (prefix, path, tree) }
        }
        return nil
    }

    private func changesPane(
        _ changes: GitChangedFiles<GitChangeFile>,
        staged: Bool,
        original: GitChangedFiles<GitCommitFile>? = nil,
        update: @escaping ([GitChangeFile]) -> Void
    ) -> some View {
        let files = changes.files
        let originalFiles = original?.files ?? []
        let prefix = staged ? "s:" : "u:"
        let tags = changes.tags(prefix: prefix).union(original?.tags(prefix: "c:") ?? [])
        let paneSelection = selection.intersection(tags)
        let targets = paneSelection.isEmpty ? files : changes.selectedFiles(in: paneSelection, prefix: prefix)
        let action: LocalizedStringResource = staged ? "Unstage" : "Stage"
        let bulkAction: LocalizedStringResource = staged ? "Unstage All" : "Stage All"

        return VStack(spacing: 0) {
            HStack {
                Text(staged ? "Staged" : "Unstaged")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(files.count)))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: files.count)
                Button(String(localized: paneSelection.isEmpty ? bulkAction : action)) {
                    update(targets)
                }
                .foregroundStyle(ClaudeTheme.semanticForeground(ClaudeTheme.accent, on: ClaudeTheme.surfacePrimary))
                .controlSize(.small)
                .disabled(targets.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ClaudeTheme.surfacePrimary)
            ClaudeThemeDivider()
            List(selection: Binding(get: { selection.intersection(tags) }, set: { newValue in
                if !newValue.isEmpty || !selection.isDisjoint(with: tags) { selection = newValue }
            })) {
                GitChangedFileTree(changes: changes, tagPrefix: prefix, isSelected: paneSelection.contains) { file in
                    GitWorkingFileRow(file: file)
                        .flightSlot(file.displayPath, in: staged ? .staged : .unstaged, flight: flight)
                }
                if let original, !originalFiles.isEmpty {
                    Section("In original commit (\(originalFiles.count))") {
                        GitChangedFileTree(changes: original, tagPrefix: "c:", isSelected: paneSelection.contains) { file in
                            GitCommitFileRow(file: file)
                                .flightSlot(file.path, in: .original, flight: flight)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(staged ? "git-staged-files" : "git-unstaged-files")
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: files)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: originalFiles)
            .overlay {
                if files.isEmpty && originalFiles.isEmpty {
                    Text(staged ? "No staged files" : "No unstaged files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .contextMenu(forSelectionType: String.self) { selectedTags in
                let targets = changes.selectedFiles(in: selectedTags, prefix: prefix)
                if !targets.isEmpty {
                    Button(String(localized: action)) { update(targets) }
                    if !staged {
                        Button("Discard Changes…", role: .destructive) { store.confirmation = .discard(targets) }
                    }
                }
            } primaryAction: { selectedTags in
                update(changes.selectedFiles(in: selectedTags, prefix: prefix))
            }
        }
        .transformAnchorPreference(key: GitTransferAnchors.self, value: .bounds) { anchors, bounds in
            anchors[.pane(staged: staged)] = bounds
        }
    }

    private func move(_ files: [GitChangeFile], toStaged: Bool, tree: GitWorkingTree) {
        guard store.operation == nil, let first = files.first, let directory = repository.path else { return }
        let paths = files.flatMap(\.pathspecs)
        let source = toStaged ? tree.changes.trees?.unstaged : tree.changes.trees?.staged
        let prefix = toStaged ? "u:" : "s:"
        let sourceTags = selection.filter { $0.hasPrefix(prefix) }
        let selectedSources = source?.selectedFiles(in: sourceTags, prefix: prefix) ?? []
        let movingPaths = Set(files.map(\.displayPath))
        let movement = GitFileFlight(
            source: toStaged ? .unstaged : .staged,
            destination: toStaged ? .staged : .unstaged,
            items: files.prefix(GitFileFlight.maxItems).map { GitFlightItem(id: $0.displayPath, label: .change($0)) }
        )
        flight = reduceMotion ? nil : movement
        if files.count == 1 {
            store.operation = toStaged ? "Staging \(first.name)…" : "Unstaging \(first.name)…"
        } else {
            store.operation = toStaged ? "Staging \(files.count) files…" : "Unstaging \(files.count) files…"
        }

        Task {
            let failure = if toStaged {
                await GitHelper.stage(paths: paths, at: tree.root)
            } else {
                await GitHelper.unstage(paths: paths, at: tree.root)
            }
            store.operation = "Updating file lists…"
            await repository.refresh(at: directory)
            store.operation = nil
            store.error = failure

            guard failure == nil, case .ready(let current) = repository.state,
                  current.root == tree.root, current.headCommit == tree.headCommit, current.head == tree.head else {
                if flight?.id == movement.id { flight = nil }
                return
            }
            let destination = toStaged ? current.changes.staged : current.changes.unstaged
            func landing(for file: GitChangeFile) -> GitChangeFile? {
                destination.first { !Set($0.pathspecs).isDisjoint(with: file.pathspecs) }
            }

            // Selection follows each file into the other list.
            let landed = selectedSources.filter { movingPaths.contains($0.displayPath) }.compactMap(landing(for:))
            if !landed.isEmpty {
                selection.subtract(sourceTags)
                selection.formUnion(selectedSources.filter { !movingPaths.contains($0.displayPath) }.map(Self.tag))
                selection.formUnion(landed.map(Self.tag))
            }

            guard flight?.id == movement.id, var updated = flight else { return }
            updated.items = updated.items.compactMap { item in
                guard case .change(let file) = item.label, let target = landing(for: file) else { return nil }
                return GitFlightItem(id: item.id, label: .change(target), landingPath: target.displayPath)
            }
            updated.landing = true
            flight = updated.items.isEmpty ? nil : updated
        }
    }

    /// Turning Amend off sends the original commit's rows back into the checkbox before they leave the list.
    private func setAmend(_ isOn: Bool, originalFiles: [GitCommitFile]) {
        guard !isOn, !reduceMotion, !originalFiles.isEmpty else {
            amend = isOn
            return
        }
        flight = GitFileFlight(source: .original, destination: nil, items: originalFiles.prefix(GitFileFlight.maxItems).map {
            GitFlightItem(id: $0.path, label: .commit($0))
        })
    }

    /// Runs once the overlay has measured where each row starts.
    private func captured(_ captured: GitFileFlight) {
        guard flight?.id == captured.id else { return }
        flight?.lifted = true
        if captured.source == nil || captured.destination == nil {
            if captured.source == .original { amend = false }
            flight?.landing = true
        }
    }
}

private extension View {
    /// Reports where a row sits and hides it while a stand-in flies to or from it.
    func flightSlot(_ path: String, in pane: GitFlightPane, flight: GitFileFlight?) -> some View {
        let tracked = flight?.tracks(path) == true
        return opacity(flight?.hides(path, in: pane) == true ? 0 : 1)
            .anchorPreference(key: GitTransferAnchors.self, value: .bounds) { bounds in
                tracked ? [.row(pane, path): bounds] : [:]
            }
    }
}

/// Detail column for a working tree file.
private struct GitLocalChangeDiffView: View {
    let file: GitChangeFile?
    let onClose: () -> Void

    var body: some View {
        if let file {
            FileDiffView(filePath: file.path, fileName: file.name, gitDiffMode: file.diffMode, onClose: onClose)
                .id("\(file.diffMode)-\(file.path)")
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Choose one changed file to see its diff."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
