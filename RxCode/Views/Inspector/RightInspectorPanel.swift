import SwiftUI
import RxCodeCore

// MARK: - RightInspectorPanel

/// Right-side panel with two modes:
/// - Review: This thread / Unstaged / Staged / Branch tabs.
/// - Inspector: Memo / Terminal tabs.
/// Per-terminal instance state. A thread can have multiple of these.
struct InspectorTerminal: Identifiable {
    let id: UUID
    let process: TerminalProcess
    var resetID: UUID
    /// User-set title. When nil, the UI falls back to "Terminal N".
    var customTitle: String?
}

struct RightInspectorPanel: View {
    @Environment(WindowState.self) private var windowState

    // Per-thread terminal storage. Each session/thread can have multiple
    // terminals; all stay alive across thread switches.
    @State private var terminalsBySession: [String: [InspectorTerminal]] = [:]
    @State private var activeTerminalIdBySession: [String: UUID] = [:]
    @State private var memoClearID: UUID? = nil
    @State private var terminalFocusID: UUID? = nil
    @State private var memoFocusID: UUID? = nil

    private var currentSessionKey: String {
        windowState.currentSessionId ?? windowState.newSessionKey
    }

    private var currentTerminals: [InspectorTerminal] {
        terminalsBySession[currentSessionKey] ?? []
    }

    private var activeTerminalId: UUID? {
        activeTerminalIdBySession[currentSessionKey]
    }

    private var activeTerminal: InspectorTerminal? {
        guard let id = activeTerminalId else { return nil }
        return currentTerminals.first { $0.id == id }
    }

    private func bumpFocus(for tab: InspectorTab) {
        switch tab {
        case .terminal: terminalFocusID = UUID()
        case .memo: memoFocusID = UUID()
        case .run: break
        }
    }

    private func ensureTerminal(for key: String) {
        if (terminalsBySession[key]?.isEmpty ?? true) {
            let t = InspectorTerminal(id: UUID(), process: TerminalProcess(), resetID: UUID())
            terminalsBySession[key] = [t]
            activeTerminalIdBySession[key] = t.id
        } else if activeTerminalIdBySession[key] == nil,
                  let first = terminalsBySession[key]?.first {
            activeTerminalIdBySession[key] = first.id
        }
    }

    private func addTerminalToCurrent() {
        let key = currentSessionKey
        let t = InspectorTerminal(id: UUID(), process: TerminalProcess(), resetID: UUID())
        terminalsBySession[key, default: []].append(t)
        activeTerminalIdBySession[key] = t.id
        terminalFocusID = UUID()
    }

    private func selectTerminal(_ id: UUID) {
        activeTerminalIdBySession[currentSessionKey] = id
        terminalFocusID = UUID()
    }

    private func closeTerminal(_ id: UUID) {
        let key = currentSessionKey
        guard var list = terminalsBySession[key],
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].process.terminate()
        list.remove(at: idx)
        if list.isEmpty {
            let t = InspectorTerminal(id: UUID(), process: TerminalProcess(), resetID: UUID())
            list.append(t)
            activeTerminalIdBySession[key] = t.id
        } else if activeTerminalIdBySession[key] == id {
            let newActive = list[max(0, idx - 1)]
            activeTerminalIdBySession[key] = newActive.id
        }
        terminalsBySession[key] = list
    }

    private func resetActiveTerminal() {
        let key = currentSessionKey
        guard var list = terminalsBySession[key],
              let id = activeTerminalIdBySession[key],
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].process.terminate()
        list[idx] = InspectorTerminal(
            id: list[idx].id,
            process: TerminalProcess(),
            resetID: UUID(),
            customTitle: list[idx].customTitle
        )
        terminalsBySession[key] = list
    }

    private func clearActiveTerminal() {
        activeTerminal?.process.clear()
    }

    private func renameTerminal(_ id: UUID, title: String) {
        let key = currentSessionKey
        guard var list = terminalsBySession[key],
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        list[idx].customTitle = trimmed.isEmpty ? nil : trimmed
        terminalsBySession[key] = list
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch windowState.inspectorMode {
                case .review:
                    reviewContent
                case .inspector:
                    InspectorContentView(
                        terminalsBySession: terminalsBySession,
                        currentSessionKey: currentSessionKey,
                        activeTerminalId: activeTerminalId,
                        memoClearID: memoClearID,
                        terminalFocusID: terminalFocusID,
                        memoFocusID: memoFocusID,
                        onSelectTerminal: selectTerminal,
                        onCloseTerminal: closeTerminal,
                        onAddTerminal: addTerminalToCurrent,
                        onRenameTerminal: renameTerminal
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudeTheme.surfaceElevated)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ClaudeTheme.borderSubtle.opacity(0.6))
                .frame(width: 0.5)
        }
        .frame(
            minWidth: windowState.showInspector ? 340 : 0,
            maxWidth: windowState.showInspector ? .infinity : 0
        )
        .opacity(windowState.showInspector ? 1 : 0)
        .clipped()
        .background(terminalShortcuts)
        .task(id: currentSessionKey) {
            ensureTerminal(for: currentSessionKey)
            // Always open the terminal for the current thread.
            windowState.inspectorMode = .inspector
            windowState.inspectorTab = .terminal
            windowState.showInspector = true
        }
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

    /// Hidden buttons that register keyboard shortcuts (Cmd+K clear, Cmd+T new)
    /// scoped to when the inspector is showing the terminal tab.
    @ViewBuilder
    private var terminalShortcuts: some View {
        if windowState.showInspector,
           windowState.inspectorMode == .inspector,
           windowState.inspectorTab == .terminal {
            ZStack {
                Button("Clear Terminal", action: clearActiveTerminal)
                    .keyboardShortcut("k", modifiers: .command)
                Button("New Terminal", action: addTerminalToCurrent)
                    .keyboardShortcut("t", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            ModeSwitchControl(selection: Bindable(windowState).inspectorMode)

            switch windowState.inspectorMode {
            case .review:
                ReviewTabPicker(selection: Bindable(windowState).inspectorReviewTab)
            case .inspector:
                InspectorTabPicker(
                    selection: Bindable(windowState).inspectorTab,
                    onTabClick: { tab in bumpFocus(for: tab) }
                )
            }

            Spacer()

            if windowState.inspectorMode == .inspector {
                if windowState.inspectorTab == .terminal {
                    HeaderIconButton(systemImage: "plus", help: "New Terminal (⌘T)") {
                        addTerminalToCurrent()
                    }
                    HeaderIconButton(systemImage: "eraser", help: "Clear Terminal (⌘K)") {
                        clearActiveTerminal()
                    }
                    HeaderIconButton(systemImage: "arrow.counterclockwise", help: "Reset Terminal") {
                        resetActiveTerminal()
                    }
                } else if windowState.inspectorTab == .memo {
                    HeaderIconButton(systemImage: "trash", help: "Clear Memo") {
                        memoClearID = UUID()
                    }
                }
            }

            HeaderIconButton(systemImage: "xmark", help: "Close") {
                windowState.showInspector = false
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ClaudeTheme.surfaceElevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ClaudeTheme.borderSubtle.opacity(0.5))
                .frame(height: 0.5)
        }
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
        HStack(spacing: 0) {
            ForEach(InspectorMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = mode }
                } label: {
                    Text(LocalizedStringKey(mode.rawValue))
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : ClaudeTheme.textTertiary)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(ClaudeTheme.accent)
                                        .shadow(color: ClaudeTheme.accent.opacity(0.25), radius: 3, x: 0, y: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - HeaderPickerLabel

/// Shared chevron-down dropdown label used by both Review and Inspector mode.
private struct HeaderPickerLabel: View {
    let icon: String?
    let title: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: ClaudeTheme.size(9), weight: .bold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.leading, 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            (isHovered ? ClaudeTheme.surfaceSecondary : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(ClaudeTheme.borderSubtle.opacity(isHovered ? 0.6 : 0.0), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - ReviewTabPicker

private struct ReviewTabPicker: View {
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
            HeaderPickerLabel(icon: nil, title: selection.rawValue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - InspectorTabPicker

private struct InspectorTabPicker: View {
    @Binding var selection: InspectorTab
    var onTabClick: (InspectorTab) -> Void = { _ in }

    var body: some View {
        Menu {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                    onTabClick(tab)
                } label: {
                    HStack {
                        Image(systemName: tab.icon)
                        Text(LocalizedStringKey(tab.rawValue))
                        if selection == tab { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HeaderPickerLabel(icon: selection.icon, title: selection.rawValue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - HeaderIconButton

private struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(isHovered ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    isHovered ? ClaudeTheme.surfaceSecondary : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
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
