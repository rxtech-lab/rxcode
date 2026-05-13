import AppKit
import ClarcCore
import SwiftUI

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
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            TodoProgressToolbarItem()
                .padding(.horizontal)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.startNewChat(in: windowState)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New Chat")

            ExternalEditorMenu()

            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    let path = windowState.selectedProject?.path ?? ""
                    openWindow(id: "terminal-window", value: TerminalWindowValue(path: path))
                } else {
                    windowState.inspectorMode = .inspector
                    windowState.inspectorTab = .terminal
                    windowState.showInspector = true
                }
            } label: {
                Image(systemName: "apple.terminal")
            }
            .help("Open Terminal (\u{2325}-click for window)")

            Button {
                windowState.inspectorMode = .inspector
                windowState.inspectorTab = .memo
                windowState.showInspector = true
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
