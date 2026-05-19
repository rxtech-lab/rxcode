import AppKit
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
            minWidth: windowState.showInspector ? 420 : 0,
            maxWidth: windowState.showInspector ? .infinity : 0
        )
        .opacity(windowState.showInspector ? 1 : 0)
        .clipped()
        .background(terminalShortcuts)
        .task(id: currentSessionKey) {
            ensureTerminal(for: currentSessionKey)
            // Keep the user's last-chosen inspector mode/tab (persisted in
            // WindowState). Just make sure the panel is visible and the
            // terminal process exists for this session.
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
        .onChange(of: windowState.clearTerminalRequest) { _, _ in
            // Routed from the global Cmd+K handler in MainView when the terminal
            // tab is the active inspector tab. Avoids a duplicate keyboardShortcut
            // collision with the global-search shortcut.
            clearActiveTerminal()
        }
    }

    /// Hidden button that registers the Cmd+T new-terminal shortcut, scoped to
    /// when the inspector is showing the terminal tab. Cmd+K is intentionally
    /// not registered here — it's routed via `WindowState.clearTerminalRequest`
    /// from the single global Cmd+K handler in MainView.
    @ViewBuilder
    private var terminalShortcuts: some View {
        if windowState.showInspector,
           windowState.inspectorMode == .inspector,
           windowState.inspectorTab == .terminal {
            Button("New Terminal", action: addTerminalToCurrent)
                .keyboardShortcut("t", modifiers: .command)
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
        case .changes:
            ChangesView()
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

// MARK: - ChangeSection

private struct ChangeSection: View {
    let title: String
    let actionTitle: String
    let files: [GitChangeFile]
    @Binding var selection: Set<String>
    let emptyMessage: String
    let isBusy: Bool
    let onAction: () async -> Void
    let onFocus: () -> Void
    let onEmptyTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if files.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                ChangeFileRow(
                                    file: file,
                                    isSelected: selection.contains(file.displayPath),
                                    onPrimarySelect: {
                                        onFocus()
                                        selectOnly(file)
                                    },
                                    onSecondarySelect: { isCommandPressed in
                                        onFocus()
                                        if isCommandPressed {
                                            toggle(file)
                                        } else {
                                            selectOnly(file)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the empty area inside a section focuses it and clears
            // all selections (both unstaged and staged). Taps on rows are
            // intercepted by the row's own gesture, so this only fires on
            // the background.
            onFocus()
            onEmptyTap()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text("\(files.count)")
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(ClaudeTheme.surfaceSecondary, in: Capsule())
            Spacer()
            Button {
                Task { await onAction() }
            } label: {
                Text(LocalizedStringKey(actionTitle))
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty || isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.4))
    }

    private func toggle(_ file: GitChangeFile) {
        if selection.contains(file.displayPath) {
            selection.remove(file.displayPath)
        } else {
            selection.insert(file.displayPath)
        }
    }

    private func selectOnly(_ file: GitChangeFile) {
        selection = [file.displayPath]
    }
}

// MARK: - ChangeFileRow

private struct ChangeFileRow: View {
    let file: GitChangeFile
    let isSelected: Bool
    let onPrimarySelect: () -> Void
    let onSecondarySelect: (_ isCommandPressed: Bool) -> Void

    @Environment(WindowState.self) private var windowState
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.parentDirectory.isEmpty {
                    Text(file.parentDirectory)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent.opacity(0.8) : ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            Text(badgeLabel)
                .font(.system(size: ClaudeTheme.size(9), weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : iconColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    (isSelected ? ClaudeTheme.textOnAccent.opacity(0.2) : iconColor.opacity(0.15)),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture { onPrimarySelect() }
        .overlay {
            ChangeFileRightClickOverlay(
                onRightClick: onSecondarySelect,
                onShowDiff: openDiff
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onHover { isHovering = $0 }
        .help("Click to select · Command-right-click to add or remove · Right-click for Show Diff")
    }

    private func openDiff() {
        windowState.diffFile = PreviewFile(
            path: file.path,
            name: file.name,
            gitDiffMode: file.diffMode
        )
    }

    private var rowFill: Color {
        if isSelected { return ClaudeTheme.accent }
        if isHovering { return ClaudeTheme.surfaceSecondary }
        return .clear
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

private struct ChangeFileRightClickOverlay: NSViewRepresentable {
    let onRightClick: (_ isCommandPressed: Bool) -> Void
    let onShowDiff: () -> Void

    func makeNSView(context: Context) -> RightClickSelectionView {
        let view = RightClickSelectionView()
        view.onRightClick = onRightClick
        view.onShowDiff = onShowDiff
        return view
    }

    func updateNSView(_ nsView: RightClickSelectionView, context: Context) {
        nsView.onRightClick = onRightClick
        nsView.onShowDiff = onShowDiff
    }
}

private final class RightClickSelectionView: NSView {
    var onRightClick: ((_ isCommandPressed: Bool) -> Void)?
    var onShowDiff: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent,
              event.type == .rightMouseDown else {
            return nil
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        onRightClick?(modifiers.contains(.command))
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        let showDiffItem = NSMenuItem(title: "Show Diff", action: #selector(showDiff), keyEquivalent: "")
        showDiffItem.target = self
        menu.addItem(showDiffItem)
        menu.popUp(positioning: showDiffItem, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func showDiff() {
        onShowDiff?()
    }
}

// MARK: - Loading

struct GitChangeFile: Identifiable, Hashable {
    let id = UUID()
    let path: String        // absolute path
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

private struct GitChangesSnapshot {
    let unstaged: [GitChangeFile]
    let staged: [GitChangeFile]
}

private func loadAllChangedFiles(at projectPath: String) async -> GitChangesSnapshot {
    guard let raw = await GitHelper.run(["status", "--porcelain=v1", "-z"], at: projectPath) else {
        return GitChangesSnapshot(unstaged: [], staged: [])
    }
    return parsePorcelainZ(raw, projectPath: projectPath)
}

/// Parses `git status --porcelain=v1 -z` output into both unstaged and staged
/// file lists. Entries are NUL-terminated; renames have an extra NUL-terminated
/// "old path" record.
private func parsePorcelainZ(_ raw: String, projectPath: String) -> GitChangesSnapshot {
    var unstaged: [GitChangeFile] = []
    var staged: [GitChangeFile] = []
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
            i += 1
        }

        let absolute = (projectPath as NSString).appendingPathComponent(displayPath)

        // Unstaged includes untracked files and any worktree-side change.
        if isUntracked || (worktreeChar != " " && worktreeChar != "?") {
            let statusChar: Character = isUntracked ? "?" : worktreeChar
            let diffMode: PreviewFile.GitDiffMode = isUntracked ? .untracked : .unstaged
            unstaged.append(GitChangeFile(
                path: absolute,
                displayPath: displayPath,
                statusChar: statusChar,
                isUntracked: isUntracked,
                diffMode: diffMode
            ))
        }

        // Staged: anything with an index-side change other than '?'.
        if !isUntracked, indexChar != " " {
            staged.append(GitChangeFile(
                path: absolute,
                displayPath: displayPath,
                statusChar: indexChar,
                isUntracked: false,
                diffMode: .staged
            ))
        }
    }
    let sort: ([GitChangeFile]) -> [GitChangeFile] = { files in
        files.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }
    return GitChangesSnapshot(unstaged: sort(unstaged), staged: sort(staged))
}
