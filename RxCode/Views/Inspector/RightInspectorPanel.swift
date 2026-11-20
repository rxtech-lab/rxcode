import AppKit
import RxCodeCore
import SwiftUI

struct RightInspectorPanel: View {
    let width: CGFloat

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(WorkspaceDesignSession.self) private var design
    @State private var terminals = InspectorTerminalStore()
    @State private var toolbarInset: CGFloat = 0

    private var isShowing: Bool { appState.showRightSidebar }

    var body: some View {
        InspectorPaneStack(layout: Bindable(windowState).inspectorLayout.destinations,
                           accessibilityIdentifier: "inspector-destination-pane", minimumPaneHeight: 208) { pane, actions in
            header(for: pane, actions: actions)
        } content: { pane in
            if isShowing, let mode = pane.selectedTab {
                switch mode {
                case .review: reviewContent
                case .inspector: InspectorToolsView(terminals: terminals)
                case .preview: WorkspacePreviewInspector()
                case .browser:
                    WorkspaceBrowserView(isFocused: windowState.inspectorMode == .browser)
                        .environment(design.inspectorBrowser)
                }
            }
        }
        .padding(.top, toolbarInset)
        .background {
            InspectorToolbarInsetReader { toolbarInset = $0 }
                .allowsHitTesting(false)
        }
        .background(ClaudeTheme.surfaceElevated)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ClaudeTheme.borderSubtle.opacity(0.6))
                .frame(width: 0.5)
                .allowsHitTesting(false)
        }
        .frame(width: width)
        .opacity(isShowing ? 1 : 0)
        .allowsHitTesting(isShowing)
        .accessibilityHidden(!isShowing)
        .clipped()
        .onChange(of: isShowing) { _, visible in
            if !visible { windowState.inspectorExpanded = false }
        }
        .onChange(of: windowState.inspectorLayout.tools.tabIDs) { _, ids in
            terminals.retainTabs(ids)
            windowState.inspectorRunTaskIDs = windowState.inspectorRunTaskIDs.filter { ids.contains($0.key) }
        }
    }

    private func header(for pane: InspectorDestinationLayout.Pane, actions: InspectorPaneTabActions<InspectorDestinationDrag>) -> some View {
        let mode = pane.selectedTab
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                InspectorDestinationBar(pane: pane, actions: actions)
                if pane.id == windowState.inspectorLayout.destinations.panes.first?.id {
                    panelControls
                }
            }

            if mode == .review {
                WorkspaceChipTabPicker(
                    options: InspectorReviewTab.allCases,
                    selection: Bindable(windowState).inspectorReviewTab,
                    accessibilityPrefix: "inspector-review"
                ) { tab, selected in
                    WorkspaceChipTabLabel(title: tab.title, systemImage: tab.icon, isSelected: selected)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Review")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, mode == .inspector ? 0 : mode == .review ? 6 : 10)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.4))
        .overlay(alignment: .bottom) {
            if mode != .inspector { Divider() }
        }
    }

    @ViewBuilder
    private var panelControls: some View {
        let expanded = windowState.inspectorExpanded
        HeaderIconButton(
            systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            help: expanded ? "Exit full width" : "Expand to full width"
        ) {
            if !expanded { windowState.floatingChatMinimized = false }
            windowState.inspectorExpanded.toggle()
        }
        .accessibilityLabel(expanded ? "Exit full width" : "Expand to full width")
        .accessibilityIdentifier("inspector-expand")

        HeaderIconButton(systemImage: "sidebar.right", help: "Hide inspector") {
            windowState.inspectorExpanded = false
            appState.showRightSidebar = false
        }
        .accessibilityLabel("Hide inspector")
    }

    @ViewBuilder
    private var reviewContent: some View {
        switch windowState.inspectorReviewTab {
        case .thisThread: ThisThreadDiffView()
        case .changes: ChangesView()
        case .branch: BranchInfoView()
        }
    }
}

/// Keeps the header below the toolbar when the window draws its background into the title bar.
private struct InspectorToolbarInsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> MeasuringView { MeasuringView() }

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
                guard let window else { return }
                let inset = max(0, convert(bounds, to: nil).maxY - window.contentLayoutRect.maxY)
                guard inset != reportedInset else { return }
                reportedInset = inset
                onChange?(inset)
            }
        }
    }
}

private extension InspectorReviewTab {
    var icon: String {
        switch self {
        case .thisThread: "bubble.left.and.text.bubble.right"
        case .changes: "plusminus"
        case .branch: "arrow.triangle.branch"
        }
    }
}
