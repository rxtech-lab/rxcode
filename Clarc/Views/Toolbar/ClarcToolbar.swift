import SwiftUI
import ClarcCore

// MARK: - ClarcToolbar

/// Shared trailing toolbar group: New Chat, Open in Editor, Terminal,
/// Memo, Inspector toggle, Settings.
///
/// Wrapped in an isolated struct so toolbar reads do not trigger NSToolbar
/// re-layout when `selectedProject` changes.
struct ClarcToolbarContent: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .confirmationAction) {
            Button {
                appState.startNewChat(in: windowState)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New Chat")

            ExternalEditorMenu()

            Button {
                if let path = windowState.selectedProject?.path {
                    openWindow(id: "terminal-window", value: TerminalWindowValue(path: path))
                } else {
                    openWindow(id: "terminal-window", value: TerminalWindowValue(path: ""))
                }
            } label: {
                Image(systemName: "apple.terminal")
            }
            .help("Open Terminal")

            Button {
                windowState.showMemoPopover.toggle()
            } label: {
                Image(systemName: "note.text")
            }
            .help("Memo")

            Button {
                windowState.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle Inspector")
            .keyboardShortcut("4", modifiers: .command)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }
}

// MARK: - Memo Popover Content

struct MemoPopoverContent: View {
    @Environment(WindowState.self) private var windowState
    @State private var clearTrigger: UUID? = nil
    @State private var focusTrigger: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memo")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Button {
                    clearTrigger = UUID()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Clear Memo")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ClaudeThemeDivider()

            InspectorMemoPanel(
                projectId: windowState.selectedProject?.id,
                clearTrigger: clearTrigger,
                focusTrigger: focusTrigger
            )
        }
        .frame(width: 420, height: 480)
        .onAppear { focusTrigger = UUID() }
    }
}
