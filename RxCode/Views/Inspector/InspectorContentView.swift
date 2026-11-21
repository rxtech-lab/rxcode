import SwiftUI
import RxCodeCore

// MARK: - InspectorContentView

/// Content for a Terminal, Run, or Views tab. Terminal sessions belong to the tab.
struct InspectorContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let tab: InspectorToolLayout.Tab
    let isFocused: Bool
    let store: InspectorTerminalStore
    @State private var terminalFocusID: UUID?
    @State private var draggingTerminalID: UUID?

    private var terminalKey: InspectorTerminalStore.Key {
        .init(tabID: tab.id, sessionID: windowState.currentSessionId ?? windowState.newSessionKey)
    }

    private var runs: [RunTask] { appState.runService.tasks }

    private var showsLiveRunTerminal: Bool {
        // A run owns one AppKit view. When multiple panes display the same
        // run, give that view to the focused pane and show its log in the others.
        func runID(for tabID: UUID) -> UUID? {
            let stored = windowState.inspectorRunTaskIDs[tabID]
            return runs.first(where: { $0.id == stored })?.id ?? runs.first?.id
        }
        let selectedRun = runID(for: tab.id)
        let layout = windowState.inspectorLayout.tools
        let contenders = layout.panes.compactMap(\.selectedTab).filter {
            $0.tool == .run && runID(for: $0.id) == selectedRun
        }
        let focused = layout.selectedTab?.id
        return (contenders.first { $0.id == focused } ?? contenders.first)?.id == tab.id
    }

    var body: some View {
        VStack(spacing: 0) {
            switch tab.tool {
            case .terminal:
                if let session = store.sessions[terminalKey], let activeTerminal = session.active {
                    terminalTabBar(session)
                    Group {
                        EmbeddedTerminalView(
                            executable: "/bin/zsh",
                            arguments: ["-il"],
                            currentDirectory: windowState.selectedProject?.path,
                            process: activeTerminal.process,
                            focusTrigger: isFocused ? terminalFocusID : nil,
                            autofocus: isFocused
                        )
                        .id(activeTerminal.resetID)
                    }
                    .padding(8)
                    .background(ClaudeTheme.codeBackground)
                }
            case .run:
                RunOutputInspectorView(
                    selectedTaskID: Binding(
                        get: { windowState.inspectorRunTaskIDs[tab.id] },
                        set: { windowState.inspectorRunTaskIDs[tab.id] = $0 }
                    ),
                    showsLiveTerminal: showsLiveRunTerminal
                )
            case .views:
                AgentViewsInspectorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: tab.tool == .terminal ? terminalKey : nil) {
            if tab.tool == .terminal { store.ensureSession(terminalKey) }
        }
        .onChange(of: isFocused && tab.tool == .terminal, initial: true) { _, active in
            if active { terminalFocusID = UUID() }
        }
        .onChange(of: windowState.clearTerminalRequest) { _, _ in
            if isFocused && tab.tool == .terminal { store.clearTerminal(in: terminalKey) }
        }
        .background {
            if isFocused, tab.tool == .terminal {
                Button("New Terminal", action: addTerminal)
                    .keyboardShortcut("t", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func addTerminal() {
        windowState.inspectorLayout.tools.select(tab.id)
        store.addTerminal(in: terminalKey)
        terminalFocusID = UUID()
    }

    private func terminalTabBar(_ session: InspectorTerminalStore.Session) -> some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(session.terminals) { terminal in
                        TerminalTabChip(
                            title: terminal.title,
                            isActive: terminal.id == session.activeID,
                            canClose: session.terminals.count > 1,
                            onSelect: {
                                windowState.inspectorLayout.tools.select(tab.id)
                                store.selectTerminal(terminal.id, in: terminalKey)
                                terminalFocusID = UUID()
                            },
                            onClose: { store.closeTerminal(terminal.id, in: terminalKey) },
                            onRename: { store.renameTerminal(terminal.id, title: $0, in: terminalKey) }
                        )
                        .workspaceReorderableTab(id: terminal.id, draggingID: $draggingTerminalID) { dragged, target in
                            store.moveTerminal(dragged, to: target, in: terminalKey)
                        }
                    }
                }
                .frame(height: 30)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: addTerminal)
                    .accessibilityHidden(true)
            }
            .workspaceTabStripDropArea(draggingID: $draggingTerminalID) { dragged, target in
                store.moveTerminal(dragged, to: target, in: terminalKey)
            }
            WorkspaceTabStripButton(systemImage: "plus", help: "New Terminal (⌘T)", action: addTerminal)
        }
        .padding(.horizontal, 8)
        .background(ClaudeTheme.codeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ClaudeTheme.borderSubtle.opacity(0.5))
                .frame(height: 0.5)
        }
        .onChange(of: session.terminals.map(\.id)) { _, ids in
            if let draggingTerminalID, !ids.contains(draggingTerminalID) { self.draggingTerminalID = nil }
        }
    }
}

// MARK: - TerminalTabChip

/// A terminal session tab: a quiet label with an accent underline when active,
/// one level below the tool tabs above it.
private struct TerminalTabChip: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    private func commit() {
        onRename(draft)
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }

    private func beginRename() {
        draft = title
        isEditing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .frame(minWidth: 60, idealWidth: 90)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(title)
                    .font(.system(size: ClaudeTheme.size(11), weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive || isHovering ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            if canClose {
                WorkspaceTabCloseButton(isVisible: !isEditing && (isHovering || isActive),
                                        help: "Close Terminal", action: onClose)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, canClose ? 4 : 10)
        .workspaceUnderlineTab(selected: isActive, hovered: isHovering)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: beginRename)
        .onTapGesture { if !isEditing { onSelect() } }
        .contextMenu {
            Button("Rename…", action: beginRename)
            if canClose {
                Button("Close Terminal", role: .destructive, action: onClose)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - InspectorIconButton

struct InspectorIconButton: View {
    let help: String
    let systemImage: String
    let action: () -> Void

    init(help: String, systemImage: String = "arrow.counterclockwise", action: @escaping () -> Void) {
        self.help = help
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
