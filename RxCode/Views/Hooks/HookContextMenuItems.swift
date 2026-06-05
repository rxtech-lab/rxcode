import RxCodeCore
import SwiftUI

/// Renders hook-supplied serializable `MenuItem`s as context-menu content,
/// wiring taps to the desktop menu action handler so commands dispatch locally
/// and deep links open their sheet. Mobile renders the same `MenuItem`s with its
/// own handler.
struct HookContextMenuItems: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    let items: [MenuItem]

    var body: some View {
        MenuItemsView(items)
            .menuActionHandler(appState.desktopMenuActionHandler(navigatingIn: windowState))
    }
}
