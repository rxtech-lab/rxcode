import AppKit
import RxCodeCore
import SwiftUI

/// Places the right inspector beside the workspace. When expanded, the
/// inspector covers the detail column (the project sidebar stays visible) and
/// the chat floats above it as a minimizable bubble.
struct InspectorWorkspaceLayout<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @GestureState private var resizeTranslation: CGFloat = 0
    @State private var toolbarInset: CGFloat = 0
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
            let reservedWidth = showing && !expanded ? panelWidth : 0

            ZStack(alignment: .trailing) {
                // Keep the inspector at the window edge when the navigation split
                // view needs more width than the space left beside it.
                content
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.trailing, reservedWidth)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                if inspectorStarted {
                    RightInspectorPanel(width: showing ? inspectorWidth : 0, toolbarInset: toolbarInset)
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
            .background {
                InspectorToolbarInsetReader { toolbarInset = $0 }
                    .allowsHitTesting(false)
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

/// Reports the portion of the full-size window covered by its title bar and toolbar.
private struct InspectorToolbarInsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> MeasuringView {
        let view = MeasuringView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MeasuringView, context: Context) {
        view.onChange = onChange
        view.measureAfterLayout()
    }

    final class MeasuringView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?
        private var measurementPending = false
        private var reportedInset: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.measureAfterLayout() }
            }
            measureAfterLayout()
        }

        override func layout() {
            super.layout()
            measureAfterLayout()
        }

        func measureAfterLayout() {
            guard !measurementPending else { return }
            measurementPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                measurementPending = false
                guard let window, let onChange else { return }
                let inset = max(0, window.frame.height - window.contentLayoutRect.maxY)
                guard inset != reportedInset else { return }
                reportedInset = inset
                onChange(inset)
            }
        }
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
