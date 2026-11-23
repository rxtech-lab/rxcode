import AppKit
import RxCodeCore
import SwiftUI

extension View {
    /// Give the toolbar the label's ideal width, capped for long titles.
    func toolbarTitleWidth() -> some View {
        lineLimit(1)
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - RxCodeToolbar

/// Shared trailing toolbar group: Open in Editor, Terminal, Views, Inspector toggle.
///
/// Wrapped in an isolated struct so toolbar reads do not trigger NSToolbar
/// re-layout when `selectedProject` changes.
struct RxCodeToolbarContent: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @State private var loadedFileCount: (sessionId: String, count: Int)?

    private var fileEditLoadID: ThreadFileEditsLoadID {
        appState.threadFileEditsLoadID(sessionId: windowState.currentSessionId ?? windowState.newSessionKey)
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
                if NSEvent.modifierFlags.contains(.option) {
                    let path = windowState.selectedProject?.path ?? ""
                    openWindow(id: "terminal-window", value: TerminalWindowValue(path: path))
                } else {
                    windowState.inspectorTab = .terminal
                    appState.showRightSidebar = true
                }
            } label: {
                Image(systemName: "apple.terminal")
            }
            .help("Open Terminal (\u{2325}-click for window)")
            .accessibilityIdentifier("open-terminal-button")

            Button {
                windowState.inspectorTab = .views
                appState.showRightSidebar = true
            } label: {
                Image(systemName: InspectorTab.views.icon)
            }
            .help("Views")
            .accessibilityIdentifier("open-views-button")

            inspectorButton
        }
    }

    private var inspectorButton: some View {
        let key = fileEditLoadID
        return Button {
            appState.showRightSidebar.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
                .overlay(alignment: .topTrailing) {
                    if let loadedFileCount, loadedFileCount.sessionId == key.sessionId, loadedFileCount.count > 0 {
                        Text("\(loadedFileCount.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ClaudeTheme.foreground(on: ClaudeTheme.statusError))
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(ClaudeTheme.statusError))
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help("Toggle Inspector")
        .keyboardShortcut("4", modifiers: .command)
        .accessibilityIdentifier("toggle-inspector-button")
        .task(id: key) {
            let count = await appState.threadStoreReader.loadVisibleFileEditCount(sessionId: key.sessionId)
            guard !Task.isCancelled, fileEditLoadID == key else { return }
            loadedFileCount = (key.sessionId, count)
        }
    }
}
