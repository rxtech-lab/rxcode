import SwiftUI

/// Replaces the default macOS **Help** menu, which otherwise looks for a
/// (nonexistent) Help Book and reports "Help isn't available for RxCode"
/// (e.g. 未找到"RxCode"的帮助). Instead it opens the bundled, offline in-app
/// **User Guide** (`UserManualView`), including a direct entry that opens the
/// guide straight to its Custom Context Menus section.
///
/// Selecting an item sets `appState.userGuideRequest`; `MainView` consumes it
/// and presents the guide as a sheet.
struct DocumentationCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("RxCode User Guide") {
                appState.userGuideRequest = UserGuideRequest()
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Custom Context Menus Guide") {
                appState.userGuideRequest = UserGuideRequest(section: "custom_context_menus")
            }
        }
    }
}
