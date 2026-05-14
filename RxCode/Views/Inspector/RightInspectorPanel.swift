import SwiftUI
import RxCodeCore

// MARK: - RightInspectorPanel

/// Right-side panel with two modes:
/// - Review: This thread / Unstaged / Staged / Branch tabs.
/// - Inspector: Memo / Terminal tabs.
struct RightInspectorPanel: View {
    @Environment(WindowState.self) private var windowState

    // Inspector-mode state lives here so reset/clear buttons in the header
    // can drive the embedded views.
    @State private var inspectorProcess = TerminalProcess()
    @State private var terminalResetID = UUID()
    @State private var memoClearID: UUID? = nil
    @State private var terminalFocusID: UUID? = nil
    @State private var memoFocusID: UUID? = nil

    private func bumpFocus(for tab: InspectorTab) {
        switch tab {
        case .terminal: terminalFocusID = UUID()
        case .memo: memoFocusID = UUID()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ClaudeThemeDivider()

            Group {
                switch windowState.inspectorMode {
                case .review:
                    reviewContent
                case .inspector:
                    InspectorContentView(
                        inspectorProcess: $inspectorProcess,
                        terminalResetID: terminalResetID,
                        memoClearID: memoClearID,
                        terminalFocusID: terminalFocusID,
                        memoFocusID: memoFocusID
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudeTheme.surfaceElevated)
        .frame(
            minWidth: windowState.showInspector ? 340 : 0,
            maxWidth: windowState.showInspector ? .infinity : 0
        )
        .opacity(windowState.showInspector ? 1 : 0)
        .clipped()
        .onChange(of: windowState.inspectorTab) { _, newTab in
            if windowState.inspectorMode == .inspector { bumpFocus(for: newTab) }
        }
        .onChange(of: windowState.inspectorMode) { _, newMode in
            if newMode == .inspector, windowState.showInspector {
                bumpFocus(for: windowState.inspectorTab)
            }
        }
        .onChange(of: windowState.showInspector) { _, isShowing in
            if isShowing, windowState.inspectorMode == .inspector {
                bumpFocus(for: windowState.inspectorTab)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            ModeSwitchControl(selection: Bindable(windowState).inspectorMode)

            switch windowState.inspectorMode {
            case .review:
                ReviewTabControl(selection: Bindable(windowState).inspectorReviewTab)
            case .inspector:
                InspectorTabControl(
                    selection: Bindable(windowState).inspectorTab,
                    onTabClick: { tab in bumpFocus(for: tab) }
                )
            }

            Spacer()

            if windowState.inspectorMode == .inspector {
                if windowState.inspectorTab == .terminal {
                    InspectorIconButton(help: "Reset Terminal") {
                        inspectorProcess.terminate()
                        inspectorProcess = TerminalProcess()
                        terminalResetID = UUID()
                    }
                } else if windowState.inspectorTab == .memo {
                    InspectorIconButton(help: "Clear Memo") {
                        memoClearID = UUID()
                    }
                }
            }

            Button {
                windowState.showInspector = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Review content

    @ViewBuilder
    private var reviewContent: some View {
        switch windowState.inspectorReviewTab {
        case .thisThread:
            ThisThreadDiffView()
        case .unstaged:
            UnstagedChangesView()
        case .staged:
            StagedChangesView()
        case .branch:
            BranchInfoView()
        }
    }
}

// MARK: - ModeSwitchControl

private struct ModeSwitchControl: View {
    @Binding var selection: InspectorMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorMode.allCases, id: \.self) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(LocalizedStringKey(mode.rawValue))
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .foregroundStyle(selection == mode ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
                        .background(
                            selection == mode ? ClaudeTheme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
    }
}

// MARK: - ReviewTabControl

private struct ReviewTabControl: View {
    @Binding var selection: InspectorReviewTab

    var body: some View {
        Menu {
            ForEach(InspectorReviewTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack {
                        Text(LocalizedStringKey(tab.rawValue))
                        if selection == tab { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(selection.rawValue))
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Empty State Helper

struct InspectorEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: ClaudeTheme.size(32)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(title)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(message)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - This Thread

struct ThisThreadDiffView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var summaries: [FileEditSummary] {
        _ = appState.threadFileEditsRevision
        return appState.threadFileEdits(in: windowState)
    }

    var body: some View {
        let summaries = summaries
        if summaries.isEmpty {
            InspectorEmptyState(
                title: "No file changes yet",
                message: "This thread has not edited any files."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(summaries) { summary in
                        ThisThreadFileRow(summary: summary)
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct ThisThreadFileRow: View {
    let summary: FileEditSummary
    @Environment(WindowState.self) private var windowState
    @State private var isHovering = false

    private var additions: Int {
        summary.hunks.reduce(0) { count, hunk in
            count + nonEmptyLineCount(hunk.newString)
        }
    }

    private var deletions: Int {
        summary.hunks.reduce(0) { count, hunk in
            count + nonEmptyLineCount(hunk.oldString)
        }
    }

    private var parentDirectory: String {
        let parent = (summary.path as NSString).deletingLastPathComponent
        return parent
    }

    var body: some View {
        Button {
            windowState.diffFile = PreviewFile(
                path: summary.path,
                name: summary.name,
                editHunks: summary.hunks
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: summary.containsWrite ? "doc.badge.plus" : "pencil")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.statusWarning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !parentDirectory.isEmpty {
                        Text(parentDirectory)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    }
                    if deletions > 0 {
                        Text("−\(deletions)")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.statusError)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(isHovering ? ClaudeTheme.surfaceSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private func nonEmptyLineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return s.components(separatedBy: "\n").count
    }
}

// MARK: - Unstaged / Staged tabs — list actual files

struct UnstagedChangesView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            GitChangeListView(projectPath: project.path, mode: .unstaged)
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to see unstaged changes.")
        }
    }
}

struct StagedChangesView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            GitChangeListView(projectPath: project.path, mode: .staged)
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to see staged changes.")
        }
    }
}

struct BranchInfoView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            VStack(spacing: 0) {
                GitStatusView(projectPath: project.path)
                Spacer()
            }
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to inspect its branch.")
        }
    }
}

// MARK: - Git Change List

private enum GitChangeListMode {
    case unstaged
    case staged
}

private struct GitChangeFile: Identifiable, Hashable {
    let id = UUID()
    let path: String       // absolute path
    let displayPath: String // path relative to repo
    let statusChar: Character
    let isUntracked: Bool
    let diffMode: PreviewFile.GitDiffMode

    var name: String {
        (displayPath as NSString).lastPathComponent
    }

    var parentDirectory: String {
        (displayPath as NSString).deletingLastPathComponent
    }
}

private struct GitChangeListView: View {
    let projectPath: String
    let mode: GitChangeListMode

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var files: [GitChangeFile] = []
    @State private var isLoading = true
    @State private var headWatcher: (any DispatchSourceFileSystemObject)?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                InspectorEmptyState(
                    title: emptyTitle,
                    message: emptyMessage
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(files) { file in
                            GitChangeFileRow(file: file)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task(id: "\(projectPath)|\(modeKey)") {
            await refresh()
        }
        .onChange(of: appState.isStreaming(in: windowState)) { old, new in
            if old && !new { triggerRefresh() }
        }
        .onAppear { startWatchingHEAD() }
        .onDisappear { stopWatchingHEAD() }
        .onChange(of: projectPath) { _, _ in
            Task { @MainActor in
                stopWatchingHEAD()
                startWatchingHEAD()
            }
        }
    }

    private var modeKey: String {
        switch mode {
        case .unstaged: return "unstaged"
        case .staged: return "staged"
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .unstaged: return "No unstaged changes"
        case .staged: return "No staged changes"
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .unstaged: return "Working tree matches the index."
        case .staged: return "Nothing in the index waiting to be committed."
        }
    }

    private func triggerRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        let path = projectPath
        let m = mode
        let result = await Task.detached(priority: .userInitiated) {
            await loadChangedFiles(at: path, mode: m)
        }.value
        guard !Task.isCancelled else { return }
        files = result
        isLoading = false
    }

    private func startWatchingHEAD() {
        let headPath = projectPath + "/.git/HEAD"
        let fd = open(headPath, O_EVTONLY)
        guard fd != -1 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            let data = source?.data ?? []
            triggerRefresh()
            if !data.intersection([.delete, .rename]).isEmpty {
                stopWatchingHEAD()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startWatchingHEAD()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        headWatcher = source
    }

    private func stopWatchingHEAD() {
        headWatcher?.cancel()
        headWatcher = nil
    }
}

private struct GitChangeFileRow: View {
    let file: GitChangeFile
    @Environment(WindowState.self) private var windowState
    @State private var isHovering = false

    var body: some View {
        Button {
            windowState.diffFile = PreviewFile(
                path: file.path,
                name: file.name,
                gitDiffMode: file.diffMode
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !file.parentDirectory.isEmpty {
                        Text(file.parentDirectory)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                Text(badgeLabel)
                    .font(.system(size: ClaudeTheme.size(10), weight: .semibold, design: .monospaced))
                    .foregroundStyle(iconColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(iconColor.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(isHovering ? ClaudeTheme.surfaceSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var iconName: String {
        if file.isUntracked { return "doc.badge.plus" }
        switch file.statusChar {
        case "A": return "plus.circle"
        case "D": return "minus.circle"
        case "R": return "arrow.right.circle"
        case "C": return "doc.on.doc"
        case "U": return "exclamationmark.triangle"
        default:  return "pencil"
        }
    }

    private var iconColor: Color {
        if file.isUntracked { return ClaudeTheme.statusSuccess }
        switch file.statusChar {
        case "A": return ClaudeTheme.statusSuccess
        case "D": return ClaudeTheme.statusError
        case "U": return ClaudeTheme.statusError
        default:  return ClaudeTheme.statusWarning
        }
    }

    private var badgeLabel: String {
        if file.isUntracked { return "?" }
        return String(file.statusChar)
    }
}

private func loadChangedFiles(at projectPath: String, mode: GitChangeListMode) async -> [GitChangeFile] {
    guard let raw = await GitHelper.run(["status", "--porcelain=v1", "-z"], at: projectPath) else {
        return []
    }
    return parsePorcelainZ(raw, mode: mode, projectPath: projectPath)
}

/// Parses `git status --porcelain=v1 -z` output.
/// Entries are NUL-terminated; renames have an extra NUL-terminated "old path" record.
private func parsePorcelainZ(
    _ raw: String,
    mode: GitChangeListMode,
    projectPath: String
) -> [GitChangeFile] {
    var result: [GitChangeFile] = []
    let tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var i = 0
    while i < tokens.count {
        let entry = tokens[i]
        i += 1
        guard entry.count >= 3 else { continue }
        let chars = Array(entry)
        let indexChar = chars[0]
        let worktreeChar = chars[1]
        let displayPath = String(entry.dropFirst(3))

        let isUntracked = (indexChar == "?" && worktreeChar == "?")

        let isRename = indexChar == "R" || worktreeChar == "R"
        if isRename, i < tokens.count {
            i += 1 // skip the rename "from" path
        }

        let include: Bool
        let statusChar: Character
        switch mode {
        case .unstaged:
            include = isUntracked || (worktreeChar != " " && worktreeChar != "?")
            statusChar = isUntracked ? "?" : worktreeChar
        case .staged:
            include = !isUntracked && indexChar != " " && indexChar != "?"
            statusChar = indexChar
        }

        guard include else { continue }
        let absolute = (projectPath as NSString).appendingPathComponent(displayPath)
        let diffMode: PreviewFile.GitDiffMode
        if isUntracked {
            diffMode = .untracked
        } else {
            switch mode {
            case .unstaged: diffMode = .unstaged
            case .staged:   diffMode = .staged
            }
        }
        result.append(GitChangeFile(
            path: absolute,
            displayPath: displayPath,
            statusChar: statusChar,
            isUntracked: isUntracked && mode == .unstaged,
            diffMode: diffMode
        ))
    }
    return result.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
}
