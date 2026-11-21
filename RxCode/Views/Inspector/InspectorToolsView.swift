import RxCodeCore
import SwiftUI

struct InspectorToolsView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let terminals: InspectorTerminalStore

    var body: some View {
        InspectorPaneStack(layout: Bindable(windowState).inspectorLayout.tools,
                           accessibilityIdentifier: "inspector-tool-pane",
                           focusParent: { windowState.inspectorMode = .inspector }) { pane, actions in
            InspectorToolTabStrip(
                pane: pane, isFocused: isFocused(pane), terminals: terminals, actions: actions,
                onClose: { id in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        windowState.inspectorLayout.tools.close(id)
                    }
                }
            )
        } content: { pane in
            if let tab = pane.selectedTab {
                InspectorContentView(tab: tab, isFocused: isFocused(pane), store: terminals)
                    .id(tab.id)
            } else {
                ContentUnavailableView(
                    "No Tool Tabs",
                    systemImage: "sidebar.right",
                    description: Text("Use the Add Tool Tab menu to open Terminal, Run, or Views.")
                )
            }
        }
    }

    private func isFocused(_ pane: InspectorToolLayout.Pane) -> Bool {
        windowState.inspectorMode == .inspector && pane.id == windowState.inspectorLayout.tools.focusedPaneID
    }
}
