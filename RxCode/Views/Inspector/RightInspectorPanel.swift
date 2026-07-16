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
    private static let maximumRetainedTerminalSessions = 12

    let maxAllowedWidth: CGFloat

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    // Per-thread terminal storage. Each session/thread can have multiple
    // terminals. Inactive sessions are retained up to a bounded LRU limit.
    @State private var terminalsBySession: [String: [InspectorTerminal]] = [:]
    @State private var activeTerminalIdBySession: [String: UUID] = [:]
    @State private var terminalSessionAccessOrder: [String] = []
    @State private var memoClearID: UUID? = nil
    @State private var terminalFocusID: UUID? = nil
    @State private var memoFocusID: UUID? = nil
    @State private var resizeStartWidth: Double?

    private var currentSessionKey: String {
        windowState.currentSessionId ?? windowState.newSessionKey
    }

    private var visibleWidth: CGFloat {
        RightInspectorPanelLayout.restoredWidth(
            from: appState.rightInspectorWidth,
            maxAllowedWidth: maxAllowedWidth
        )
    }

    private var showRightSidebar: Bool {
        appState.showRightSidebar
    }

    private var terminalIsVisible: Bool {
        showRightSidebar
            && windowState.inspectorMode == .inspector
            && windowState.inspectorTab == .terminal
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
        retainTerminalSession(key)
    }

    private func ensureTerminalIfVisible() {
        guard terminalIsVisible else { return }
        ensureTerminal(for: currentSessionKey)
    }

    private func retainTerminalSession(_ key: String) {
        terminalSessionAccessOrder.removeAll { $0 == key }
        terminalSessionAccessOrder.append(key)

        while terminalSessionAccessOrder.count > Self.maximumRetainedTerminalSessions {
            let evictedKey = terminalSessionAccessOrder.removeFirst()
            guard evictedKey != key else { continue }
            terminalsBySession.removeValue(forKey: evictedKey)?.forEach { terminal in
                terminal.process.terminate()
            }
            activeTerminalIdBySession.removeValue(forKey: evictedKey)
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
                    if showRightSidebar {
                        InspectorContentView(
                            terminals: currentTerminals,
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
            width: showRightSidebar ? visibleWidth : 0
        )
        .overlay(alignment: .leading) {
            if showRightSidebar {
                resizeHandle
            }
        }
        .opacity(showRightSidebar ? 1 : 0)
        .clipped()
        .background(terminalShortcuts)
        .task(id: currentSessionKey) {
            ensureTerminalIfVisible()
        }
        .onChange(of: windowState.inspectorTab) { _, newTab in
            if windowState.inspectorMode == .inspector {
                ensureTerminalIfVisible()
                bumpFocus(for: newTab)
            }
        }
        .onChange(of: windowState.inspectorMode) { _, newMode in
            if newMode == .inspector, showRightSidebar {
                ensureTerminalIfVisible()
                bumpFocus(for: windowState.inspectorTab)
            }
        }
        .onChange(of: showRightSidebar) { _, isShowing in
            if isShowing, windowState.inspectorMode == .inspector {
                ensureTerminalIfVisible()
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
        if showRightSidebar,
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
                appState.showRightSidebar = false
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

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let startWidth = resizeStartWidth ?? Double(visibleWidth)
                        resizeStartWidth = startWidth
                        appState.rightInspectorWidth = RightInspectorPanelLayout.resizedWidth(
                            startWidth: startWidth,
                            leadingEdgeTranslation: value.translation.width,
                            maxAllowedWidth: maxAllowedWidth
                        )
                    }
                    .onEnded { _ in
                        resizeStartWidth = nil
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityHidden(true)
    }
}
