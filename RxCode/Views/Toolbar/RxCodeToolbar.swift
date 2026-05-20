import AppKit
import RxCodeCore
import SwiftUI

// MARK: - RxCodeToolbar

/// Shared trailing toolbar group: New Chat, Open in Editor, Terminal,
/// Memo, Inspector toggle, Settings.
///
/// Wrapped in an isolated struct so toolbar reads do not trigger NSToolbar
/// re-layout when `selectedProject` changes.
struct RxCodeToolbarContent: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppStorageKeys.showRightSidebar) private var showRightSidebar = false

    private var fileEditCount: Int {
        _ = appState.threadFileEditsRevision
        return appState.threadFileEdits(in: windowState).count
    }

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            TodoProgressToolbarItem()
                .padding(.horizontal)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            RunProfileToolbarGroup()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ExternalEditorMenu()

            Button {
                appState.startNewChat(in: windowState)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New Chat")

            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    let path = windowState.selectedProject?.path ?? ""
                    openWindow(id: "terminal-window", value: TerminalWindowValue(path: path))
                } else {
                    windowState.inspectorMode = .inspector
                    windowState.inspectorTab = .terminal
                    showRightSidebar = true
                }
            } label: {
                Image(systemName: "apple.terminal")
            }
            .help("Open Terminal (\u{2325}-click for window)")

            Button {
                windowState.inspectorMode = .inspector
                windowState.inspectorTab = .memo
                showRightSidebar = true
            } label: {
                Image(systemName: "note.text")
            }
            .help("Memo")

            Button {
                showRightSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .overlay(alignment: .topTrailing) {
                        let editCount = fileEditCount
                        if editCount > 0 {
                            Text("\(editCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .help("Toggle Inspector")
            .keyboardShortcut("4", modifiers: .command)
            .accessibilityIdentifier("toggle-inspector-button")

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityIdentifier("settings-button")
        }
    }
}
