import RxCodeCore
import SwiftUI

/// Places the right inspector beside the workspace. When expanded, the
/// inspector covers the detail column (the project sidebar stays visible) and
/// the chat floats above it as a minimizable bubble.
struct InspectorWorkspaceLayout<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @GestureState private var resizeTranslation: CGFloat = 0
    let inspectorStarted: Bool
    @ViewBuilder var content: Content

    private var showsFloatingChat: Bool {
        windowState.generalRoute == nil && windowState.selectedProject != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let maxWidth = RightInspectorPanelLayout.maximumWidth(in: proxy.size.width)
            let savedWidth = RightInspectorPanelLayout.restoredWidth(
                from: appState.rightInspectorWidth,
                maxAllowedWidth: maxWidth
            )
            let showing = inspectorStarted && appState.showRightSidebar
            let expanded = showing && windowState.inspectorExpanded
            let panelWidth = CGFloat(RightInspectorPanelLayout.resizedWidth(
                startWidth: Double(savedWidth),
                leadingEdgeTranslation: resizeTranslation,
                maxAllowedWidth: maxWidth
            ))
            let inspectorWidth = expanded ? max(savedWidth, windowState.detailColumnWidth) : panelWidth

            // A ZStack keeps the panel's identity, and its terminals, across modes.
            ZStack(alignment: .trailing) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, showing && !expanded ? panelWidth : 0)

                if inspectorStarted {
                    RightInspectorPanel(width: showing ? inspectorWidth : 0)
                    .overlay(alignment: .leading) {
                        if showing, !expanded {
                            resizeHandle(savedWidth: savedWidth, maxWidth: maxWidth)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if expanded, showsFloatingChat {
                            FloatingChatBubble()
                        }
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: expanded)
        }
    }

    private func resizeHandle(savedWidth: CGFloat, maxWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                // The divider moves with the drag, so use a stationary coordinate space.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resizeTranslation) { value, translation, transaction in
                        translation = value.translation.width
                        transaction.animation = nil
                    }
                    .onEnded { value in
                        let width = RightInspectorPanelLayout.resizedWidth(
                            startWidth: Double(savedWidth),
                            leadingEdgeTranslation: value.translation.width,
                            maxAllowedWidth: maxWidth
                        )
                        if width != Double(savedWidth) { appState.rightInspectorWidth = width }
                    }
            )
            .accessibilityHidden(true)
    }
}

extension View {
    /// Reports the detail column width that an expanded inspector should cover.
    func reportsInspectorDetailWidth(to windowState: WindowState) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            windowState.detailColumnWidth = width
        }
    }
}
