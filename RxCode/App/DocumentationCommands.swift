import SwiftUI

/// Replaces the default macOS **Help** menu, which otherwise looks for a
/// (nonexistent) Help Book and reports "Help isn't available for RxCode"
/// (e.g. 未找到"RxCode"的帮助). Instead it opens the bundled, offline in-app
/// **User Guide** (`UserManualView`), including direct entries for feature guides.
///
/// Guide items set `appState.userGuideRequest`; `MainView` presents the guide.
/// What's New uses the focused window's action to show the full card carousel.
struct DocumentationCommands: Commands {
    let appState: AppState
    @FocusedValue(\.showWhatsNew) private var showWhatsNew

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("RxCode User Guide") {
                appState.userGuideRequest = UserGuideRequest()
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Projects Dashboard Guide") {
                appState.userGuideRequest = UserGuideRequest(section: "tasks")
            }

            Button("Custom Context Menus Guide") {
                appState.userGuideRequest = UserGuideRequest(section: "custom_context_menus")
            }

            Divider()

            Button("What's New") {
                showWhatsNew?()
            }
            .disabled(showWhatsNew == nil)
        }
    }
}
