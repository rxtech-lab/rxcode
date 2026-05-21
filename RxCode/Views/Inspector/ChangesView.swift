import AppKit
import SwiftUI
import RxCodeCore

// MARK: - Changes (combined Unstaged + Staged + commit composer)

/// Combined view that lists unstaged files on top and staged files at the
/// bottom, with multi-select Stage/Unstage actions and a commit composer at
/// the bottom. Generates commit messages via the configured summarization
/// provider.
enum ChangeSectionFocus: Hashable {
    case unstaged
    case staged
}

struct ChangesView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    @State private var unstaged: [GitChangeFile] = []
    @State private var staged: [GitChangeFile] = []
    @State private var selectedUnstaged: Set<String> = []
    @State private var selectedStaged: Set<String> = []
    @State private var commitMessage: String = ""
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var isGenerating = false
    @State private var isPushing = false
    @State private var errorMessage: String?
    @State private var upstream: GitHelper.UpstreamStatus?
    @State private var headWatcher: (any DispatchSourceFileSystemObject)?
    @State private var indexWatcher: (any DispatchSourceFileSystemObject)?
    @State private var refreshTask: Task<Void, Never>?
    @FocusState private var focusedSection: ChangeSectionFocus?

    var body: some View {
        if let project = windowState.selectedProject {
            content(projectPath: project.path)
                .task(id: project.path) { await refresh(at: project.path) }
                .onChange(of: appState.isStreaming(in: windowState)) { old, new in
                    if old && !new { triggerRefresh(at: project.path) }
                }
                .onAppear { startWatching(at: project.path) }
                .onDisappear { stopWatching() }
                .onChange(of: project.path) { _, newPath in
                    Task { @MainActor in
                        stopWatching()
                        startWatching(at: newPath)
                    }
                }
        } else {
            InspectorEmptyState(
                title: "No project selected",
                message: "Select a project to review changes."
            )
        }
    }

    @ViewBuilder
    private func content(projectPath: String) -> some View {
        VStack(spacing: 0) {
            ChangeSection(
                title: "Unstaged",
                actionTitle: "Stage",
                files: unstaged,
                selection: $selectedUnstaged,
                emptyMessage: "Working tree matches the index.",
                isBusy: isBusy,
                onAction: { await stageSelected(at: projectPath) },
                onFocus: { focusedSection = .unstaged },
                onEmptyTap: clearAllSelections
            )
            .focusable()
            .focused($focusedSection, equals: .unstaged)

            Divider()

            ChangeSection(
                title: "Staged",
                actionTitle: "Unstage",
                files: staged,
                selection: $selectedStaged,
                emptyMessage: "Nothing in the index.",
                isBusy: isBusy,
                onAction: { await unstageSelected(at: projectPath) },
                onFocus: { focusedSection = .staged },
                onEmptyTap: clearAllSelections
            )
            .focusable()
            .focused($focusedSection, equals: .staged)

            Divider()

            commitComposer(projectPath: projectPath)
        }
        .overlay(alignment: .top) {
            if isLoading && unstaged.isEmpty && staged.isEmpty {
                ProgressView().controlSize(.small).padding(.top, 20)
            }
        }
        .background(selectAllShortcut)
    }

    /// Cmd+A hooks up to whichever section is currently focused. Hidden button
    /// avoids stealing focus from the visible UI.
    @ViewBuilder
    private var selectAllShortcut: some View {
        Button("Select All in Section") {
            selectAllInFocusedSection()
        }
        .keyboardShortcut("a", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func clearAllSelections() {
        selectedUnstaged.removeAll()
        selectedStaged.removeAll()
    }

    private func selectAllInFocusedSection() {
        switch focusedSection {
        case .unstaged:
            selectedUnstaged = Set(unstaged.map { $0.displayPath })
        case .staged:
            selectedStaged = Set(staged.map { $0.displayPath })
        case .none:
            // No section focused — default to whichever has files, preferring
            // unstaged. Keeps Cmd+A useful right after the view appears.
            if !unstaged.isEmpty {
                selectedUnstaged = Set(unstaged.map { $0.displayPath })
                focusedSection = .unstaged
            } else if !staged.isEmpty {
                selectedStaged = Set(staged.map { $0.displayPath })
                focusedSection = .staged
            }
        }
    }

    // MARK: - Commit composer

    @ViewBuilder
    private func commitComposer(projectPath: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Commit message")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer()
                Button {
                    Task { await generateMessage(at: projectPath) }
                } label: {
                    HStack(spacing: 4) {
                        if isGenerating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Generate")
                    }
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(isGenerating || staged.isEmpty)
                .help("Generate a commit message from the staged diff")
            }

            TextEditor(text: $commitMessage)
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                        .fill(ClaudeTheme.surfaceSecondary.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                        .strokeBorder(ClaudeTheme.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                upstreamStatusLabel
                Spacer()
                Button {
                    Task { await push(at: projectPath) }
                } label: {
                    HStack(spacing: 4) {
                        if isPushing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: pushIconName)
                        }
                        Text(pushLabel)
                            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || isPushing || !canPush)
                .help(pushHelp)

                Button {
                    Task { await commit(at: projectPath) }
                } label: {
                    HStack(spacing: 4) {
                        if isBusy {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Commit \(staged.count > 0 ? "(\(staged.count))" : "")")
                            .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudeTheme.accent)
                .disabled(isBusy || staged.isEmpty || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var upstreamStatusLabel: some View {
        if let upstream {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: ClaudeTheme.size(10)))
                Text(upstream.branch)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium, design: .monospaced))
                Text("·")
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text(upstreamSummary(upstream))
                    .font(.system(size: ClaudeTheme.size(11)))
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    private func upstreamSummary(_ status: GitHelper.UpstreamStatus) -> String {
        if status.upstream == nil {
            return status.remotes.isEmpty ? "no remote" : "no upstream"
        }
        switch (status.ahead, status.behind) {
        case (0, 0): return "up to date"
        case (let a, 0): return "↑\(a)"
        case (0, let b): return "↓\(b)"
        case (let a, let b): return "↑\(a) ↓\(b)"
        }
    }

    private var canPush: Bool {
        guard let upstream else { return false }
        if upstream.upstream == nil {
            // Need at least one remote to create an upstream.
            return !upstream.remotes.isEmpty
        }
        return upstream.ahead > 0
    }

    private var pushLabel: String {
        guard let upstream else { return "Push" }
        return upstream.upstream == nil ? "Publish" : "Push"
    }

    private var pushIconName: String {
        guard let upstream else { return "arrow.up" }
        return upstream.upstream == nil ? "icloud.and.arrow.up" : "arrow.up"
    }

    private var pushHelp: String {
        guard let upstream else { return "Push the current branch" }
        if upstream.upstream == nil {
            if upstream.remotes.isEmpty {
                return "No remote configured. Add one with `git remote add origin <url>`."
            }
            let remote = upstream.remotes.contains("origin") ? "origin" : (upstream.remotes.first ?? "origin")
            return "Push and track \(remote)/\(upstream.branch)"
        }
        if upstream.ahead == 0 {
            return "Nothing to push — local matches \(upstream.upstream ?? "upstream")"
        }
        return "Push \(upstream.ahead) commit\(upstream.ahead == 1 ? "" : "s") to \(upstream.upstream ?? "upstream")"
    }

    // MARK: - Actions

    private func stageSelected(at projectPath: String) async {
        let paths = selectedUnstaged.sorted()
        guard !paths.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        let err = await GitHelper.stage(paths: paths, at: projectPath)
        isBusy = false
        if let err {
            errorMessage = err
        } else {
            selectedUnstaged.removeAll()
            await refresh(at: projectPath)
        }
    }

    private func unstageSelected(at projectPath: String) async {
        let paths = selectedStaged.sorted()
        guard !paths.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        let err = await GitHelper.unstage(paths: paths, at: projectPath)
        isBusy = false
        if let err {
            errorMessage = err
        } else {
            selectedStaged.removeAll()
            await refresh(at: projectPath)
        }
    }

    private func commit(at projectPath: String) async {
        isBusy = true
        errorMessage = nil
        let err = await GitHelper.commit(message: commitMessage, at: projectPath)
        isBusy = false
        if let err {
            errorMessage = err
        } else {
            commitMessage = ""
            await refresh(at: projectPath)
        }
    }

    private func push(at projectPath: String) async {
        guard let upstream else { return }
        isPushing = true
        errorMessage = nil
        let setUpstream = upstream.upstream == nil
        let remote = upstream.remotes.contains("origin") ? "origin" : (upstream.remotes.first ?? "origin")
        let err = await GitHelper.push(
            at: projectPath,
            remote: remote,
            branch: upstream.branch,
            setUpstream: setUpstream
        )
        isPushing = false
        if let err {
            errorMessage = err
        } else {
            await refresh(at: projectPath)
        }
    }

    private func generateMessage(at projectPath: String) async {
        guard !staged.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        async let diffTask = GitHelper.stagedDiff(at: projectPath)
        async let statTask = GitHelper.stagedStat(at: projectPath)
        let (diff, stat) = await (diffTask, statTask)
        let fileSummary = staged.map { "\($0.statusChar) \($0.displayPath)" }.joined(separator: "\n")
        let result = await appState.generateCommitMessage(
            diff: diff,
            stat: stat,
            fileSummary: fileSummary
        )
        isGenerating = false
        if let result, !result.isEmpty {
            commitMessage = result
        } else {
            errorMessage = "Commit message generation is unavailable. Configure a summarization provider in Settings."
        }
    }

    // MARK: - Refresh + watching

    private func triggerRefresh(at projectPath: String) {
        refreshTask?.cancel()
        refreshTask = Task { await refresh(at: projectPath) }
    }

    private func refresh(at projectPath: String) async {
        isLoading = true
        async let filesTask = Task.detached(priority: .userInitiated) {
            await loadAllChangedFiles(at: projectPath)
        }.value
        async let upstreamTask = Task.detached(priority: .userInitiated) {
            await GitHelper.upstreamStatus(at: projectPath)
        }.value
        let (result, upstreamResult) = await (filesTask, upstreamTask)
        guard !Task.isCancelled else { return }
        unstaged = result.unstaged
        staged = result.staged
        upstream = upstreamResult
        // Drop selections for files that no longer appear.
        let unstagedPaths = Set(unstaged.map { $0.displayPath })
        let stagedPaths = Set(staged.map { $0.displayPath })
        selectedUnstaged.formIntersection(unstagedPaths)
        selectedStaged.formIntersection(stagedPaths)
        isLoading = false
    }

    private func startWatching(at projectPath: String) {
        headWatcher = makeWatcher(path: projectPath + "/.git/HEAD", projectPath: projectPath)
        indexWatcher = makeWatcher(path: projectPath + "/.git/index", projectPath: projectPath)
    }

    private func stopWatching() {
        headWatcher?.cancel()
        indexWatcher?.cancel()
        headWatcher = nil
        indexWatcher = nil
    }

    private func makeWatcher(path: String, projectPath: String) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler {
            triggerRefresh(at: projectPath)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
