import SwiftUI
import RxCodeCore

// MARK: - InspectorContentView

/// Inspector-mode body for the right sidebar: Terminal + Memo, switched by
/// `windowState.inspectorTab`. State for the terminal process and reset/clear
/// triggers is owned by the parent (`RightInspectorPanel`) so header action
/// buttons can drive them.
struct InspectorContentView: View {
    @Environment(WindowState.self) private var windowState

    let terminalsBySession: [String: [InspectorTerminal]]
    let currentSessionKey: String
    let activeTerminalId: UUID?
    let memoClearID: UUID?
    let terminalFocusID: UUID?
    let memoFocusID: UUID?
    let onSelectTerminal: (UUID) -> Void
    let onCloseTerminal: (UUID) -> Void
    let onAddTerminal: () -> Void
    let onRenameTerminal: (UUID, String) -> Void

    private struct FlatEntry: Identifiable {
        let sessionKey: String
        let terminalId: UUID
        let process: TerminalProcess
        let resetID: UUID
        var id: String { "\(sessionKey)|\(terminalId.uuidString)" }
    }

    /// Flattened list of every terminal across every session so they all stay
    /// mounted (and their shells keep running) regardless of the active thread.
    private var allEntries: [FlatEntry] {
        terminalsBySession
            .sorted { $0.key < $1.key }
            .flatMap { sessionKey, terminals in
                terminals.map { t in
                    FlatEntry(
                        sessionKey: sessionKey,
                        terminalId: t.id,
                        process: t.process,
                        resetID: t.resetID
                    )
                }
            }
    }

    private var currentTerminals: [InspectorTerminal] {
        terminalsBySession[currentSessionKey] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if currentTerminals.count > 1 || !currentTerminals.isEmpty {
                    terminalTabBar
                }
                ZStack {
                    ForEach(allEntries) { entry in
                        let isActive = entry.sessionKey == currentSessionKey
                            && entry.terminalId == activeTerminalId
                        EmbeddedTerminalView(
                            executable: "/bin/zsh",
                            arguments: ["-il"],
                            currentDirectory: windowState.selectedProject?.path,
                            process: entry.process,
                            focusTrigger: isActive ? terminalFocusID : nil
                        )
                        .id(entry.resetID)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                    }
                }
                .padding(8)
                .background(ClaudeTheme.codeBackground)
            }
            .frame(maxHeight: windowState.inspectorTab == .terminal ? .infinity : 0)
            .clipped()

            InspectorMemoPanel(projectId: windowState.selectedProject?.id,
                               clearTrigger: memoClearID,
                               focusTrigger: memoFocusID)
                .frame(maxHeight: windowState.inspectorTab == .memo ? .infinity : 0)
                .clipped()

            RunOutputInspectorView()
                .frame(maxHeight: windowState.inspectorTab == .run ? .infinity : 0)
                .clipped()
        }
    }

    @ViewBuilder
    private var terminalTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(currentTerminals.enumerated()), id: \.element.id) { index, terminal in
                    TerminalTabChip(
                        title: terminal.customTitle ?? "Terminal \(index + 1)",
                        isActive: terminal.id == activeTerminalId,
                        canClose: currentTerminals.count > 1,
                        onSelect: { onSelectTerminal(terminal.id) },
                        onClose: { onCloseTerminal(terminal.id) },
                        onRename: { newTitle in onRenameTerminal(terminal.id, newTitle) }
                    )
                }
                Button(action: onAddTerminal) {
                    Image(systemName: "plus")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            ClaudeTheme.surfaceSecondary.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .help("New Terminal (⌘T)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(ClaudeTheme.surfaceElevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ClaudeTheme.borderSubtle.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}

// MARK: - TerminalTabChip

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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "apple.terminal")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(isActive ? ClaudeTheme.textOnAccent : ClaudeTheme.textTertiary)
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(isActive ? ClaudeTheme.textOnAccent : ClaudeTheme.textPrimary)
                    .frame(minWidth: 60, idealWidth: 90)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(title)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(isActive ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            if canClose, !isEditing, isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(9), weight: .bold))
                        .foregroundStyle(isActive ? ClaudeTheme.textOnAccent.opacity(0.8) : ClaudeTheme.textTertiary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Close Terminal")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? ClaudeTheme.accent : (isHovering ? ClaudeTheme.surfaceSecondary : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draft = title
            isEditing = true
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onTapGesture { if !isEditing { onSelect() } }
        .contextMenu {
            Button("Rename…") {
                draft = title
                isEditing = true
                DispatchQueue.main.async { fieldFocused = true }
            }
            if canClose {
                Button("Close Terminal", role: .destructive, action: onClose)
            }
        }
        .onHover { isHovering = $0 }
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
