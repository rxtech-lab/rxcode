import AppKit
import SwiftUI
import RxCodeCore

/// One full-width row of the briefing timeline (header, day title, or a row of
/// cards). `content` is built inside the row's own hosting view, so observation
/// reads made while building a card only invalidate that row.
struct BriefingTimelineRow {
    let id: String
    /// Height used until the row has been rendered and measured.
    let estimatedHeight: CGFloat
    let content: @MainActor () -> AnyView
}

/// The row where a day section starts; used to place scrubber markers.
struct BriefingTimelineSectionAnchor {
    let id: String
    let date: Date
    let rowId: String
}

/// AppKit-backed briefing timeline. SwiftUI's `ScrollView` re-evaluated card
/// bodies while scrolling; here each row is an `NSHostingView` inside an
/// `NSTableView`, so scrolling only moves the clip view and rows are created
/// on demand as they come on screen. Rows keep their hosting view (and SwiftUI
/// state) for the lifetime of the timeline.
struct BriefingTimelineTableView: NSViewRepresentable {
    let rows: [BriefingTimelineRow]
    let anchors: [BriefingTimelineSectionAnchor]
    let metrics: BriefingTimelineScrollMetrics
    let showsScroller: Bool
    let onWidthChange: (CGFloat) -> Void

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = BriefingTimelineNSTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.allowsTypeSelect = false
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("briefing"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = showsScroller
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = tableView

        let coordinator = context.coordinator
        coordinator.configure(from: self)
        coordinator.attach(tableView: tableView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.hasVerticalScroller = showsScroller
        context.coordinator.configure(from: self)
        context.coordinator.update(rows: rows, anchors: anchors)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static let maximumAnimatedChanges = 16

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?

        private var metrics: BriefingTimelineScrollMetrics?
        private var onWidthChange: (CGFloat) -> Void = { _ in }
        private var appState: AppState?
        private var windowState: WindowState?

        private var rows: [BriefingTimelineRow] = []
        private var rowIndexById: [String: Int] = [:]
        private var anchors: [BriefingTimelineSectionAnchor] = []

        private var hostingViews: [String: NSHostingView<AnyView>] = [:]
        /// Cached rows whose content changed while they were off screen.
        private var staleRowIds: Set<String> = []
        private var measuredHeights: [String: CGFloat] = [:]
        private var pendingHeights: [String: CGFloat] = [:]
        private var isHeightFlushScheduled = false
        private var lastWidth: CGFloat = 0

        func configure(from view: BriefingTimelineTableView) {
            appState = view.appState
            windowState = view.windowState
            onWidthChange = view.onWidthChange
            if metrics !== view.metrics {
                metrics = view.metrics
                view.metrics.scrollHandler = { [weak self] offset in
                    self?.scroll(to: offset)
                }
            }
        }

        func attach(tableView: NSTableView, scrollView: NSScrollView) {
            self.tableView = tableView
            self.scrollView = scrollView
            tableView.dataSource = self
            tableView.delegate = self

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: clipView
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            metrics?.scrollHandler = nil
            hostingViews.removeAll()
        }

        // MARK: Updates

        func update(rows newRows: [BriefingTimelineRow], anchors newAnchors: [BriefingTimelineSectionAnchor]) {
            let oldIds = rows.map(\.id)
            let newIds = newRows.map(\.id)
            rows = newRows
            anchors = newAnchors
            rowIndexById = Dictionary(newIds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

            let liveIds = Set(newIds)
            hostingViews = hostingViews.filter { liveIds.contains($0.key) }
            measuredHeights = measuredHeights.filter { liveIds.contains($0.key) }
            staleRowIds.formIntersection(liveIds)

            guard let tableView else { return }
            if oldIds != newIds {
                applyStructuralChanges(from: oldIds, to: newIds, in: tableView)
            }

            // Row closures capture fresh state on every update. Refresh the rows on
            // screen now and the cached off-screen ones when they reappear.
            for (id, hostingView) in hostingViews {
                guard let index = rowIndexById[id] else { continue }
                if tableView.view(atColumn: 0, row: index, makeIfNecessary: false) === hostingView {
                    hostingView.rootView = rootView(for: rows[index])
                } else {
                    staleRowIds.insert(id)
                }
            }
            refreshMarkers()
            refreshScrollMetrics()
        }

        private func applyStructuralChanges(from oldIds: [String], to newIds: [String], in tableView: NSTableView) {
            var removals: [Int] = []
            var insertions: [Int] = []
            for change in newIds.difference(from: oldIds) {
                switch change {
                case .remove(let offset, _, _): removals.append(offset)
                case .insert(let offset, _, _): insertions.append(offset)
                }
            }
            // Fade small filter / data changes; rebuild outright on first load or
            // when a column-count change regroups every card row.
            guard !oldIds.isEmpty, tableView.window != nil,
                  removals.count + insertions.count <= Self.maximumAnimatedChanges else {
                tableView.reloadData()
                return
            }
            tableView.beginUpdates()
            for offset in removals.sorted(by: >) {
                tableView.removeRows(at: IndexSet(integer: offset), withAnimation: .effectFade)
            }
            for offset in insertions.sorted() {
                tableView.insertRows(at: IndexSet(integer: offset), withAnimation: .effectFade)
            }
            tableView.endUpdates()
        }

        private func rootView(for row: BriefingTimelineRow) -> AnyView {
            let id = row.id
            var root = AnyView(
                BriefingTimelineRowRoot(content: row.content) { [weak self] height in
                    self?.rowHeightDidChange(id: id, height: height)
                }
            )
            if let appState { root = AnyView(root.environment(appState)) }
            if let windowState { root = AnyView(root.environment(windowState)) }
            return root
        }

        // MARK: Row heights

        private func height(forRowAt index: Int) -> CGFloat {
            let row = rows[index]
            return measuredHeights[row.id] ?? row.estimatedHeight
        }

        private func rowHeightDidChange(id: String, height: CGFloat) {
            guard height > 0 else { return }
            if let measured = measuredHeights[id], abs(measured - height) < 0.5 {
                pendingHeights[id] = nil
                return
            }
            pendingHeights[id] = height
            guard !isHeightFlushScheduled else { return }
            isHeightFlushScheduled = true
            // Heights are reported during SwiftUI/table layout; apply them after it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.flushPendingHeights() }
            }
        }

        private func flushPendingHeights() {
            isHeightFlushScheduled = false
            let pending = pendingHeights
            pendingHeights.removeAll()
            guard let tableView, let scrollView, !pending.isEmpty else { return }

            let visibleTop = scrollView.contentView.bounds.minY
            var changed = IndexSet()
            var anchorDelta: CGFloat = 0
            for (id, height) in pending {
                guard let index = rowIndexById[id], index < tableView.numberOfRows else { continue }
                let oldHeight = self.height(forRowAt: index)
                measuredHeights[id] = height
                guard abs(oldHeight - height) >= 0.5 else { continue }
                changed.insert(index)
                // Keep the content on screen still when a row above it resizes.
                if tableView.rect(ofRow: index).maxY <= visibleTop + 0.5 {
                    anchorDelta += height - oldHeight
                }
            }
            guard !changed.isEmpty else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                tableView.noteHeightOfRows(withIndexesChanged: changed)
            }
            if anchorDelta != 0, visibleTop > 0 {
                let clipView = scrollView.contentView
                clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: visibleTop + anchorDelta))
                scrollView.reflectScrolledClipView(clipView)
            }
            refreshMarkers()
            refreshScrollMetrics()
        }

        // MARK: Scrolling

        private var contentHeight: CGFloat {
            guard let tableView, tableView.numberOfRows > 0 else { return 0 }
            return tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
        }

        private func maxOffset(in scrollView: NSScrollView) -> CGFloat {
            let insets = scrollView.contentInsets
            return max(0, contentHeight - scrollView.contentView.bounds.height + insets.top + insets.bottom)
        }

        private func refreshScrollMetrics() {
            guard let scrollView, let metrics else { return }
            let value = BriefingTimelineScrollMetrics.Value(
                offset: scrollView.contentView.bounds.minY + scrollView.contentInsets.top,
                maxOffset: maxOffset(in: scrollView)
            )
            if metrics.value != value {
                metrics.value = value
            }
        }

        private func refreshMarkers() {
            guard let tableView, let metrics else { return }
            let markers = anchors.compactMap { anchor -> BriefingTimelineMarker? in
                guard let index = rowIndexById[anchor.rowId], index < tableView.numberOfRows else { return nil }
                return BriefingTimelineMarker(id: anchor.id, date: anchor.date, offset: tableView.rect(ofRow: index).minY)
            }
            .sorted { $0.offset < $1.offset }
            if metrics.markers != markers {
                metrics.markers = markers
            }
        }

        private func scroll(to offset: CGFloat) {
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            let target = min(max(0, offset), maxOffset(in: scrollView)) - scrollView.contentInsets.top
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
            scrollView.reflectScrolledClipView(clipView)
        }

        @objc private func clipBoundsDidChange(_ notification: Notification) {
            refreshScrollMetrics()
        }

        @objc private func clipFrameDidChange(_ notification: Notification) {
            guard let scrollView, let tableView else { return }
            let width = scrollView.contentView.bounds.width
            if abs(width - lastWidth) >= 0.5 {
                lastWidth = width
                tableView.tableColumns.first?.width = width
                let onWidthChange = self.onWidthChange
                // Avoid mutating SwiftUI state from inside a layout pass.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onWidthChange(width) }
                }
            }
            refreshScrollMetrics()
        }

        // MARK: NSTableViewDataSource / NSTableViewDelegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            max(1, height(forRowAt: row))
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let timelineRow = rows[row]
            if let hostingView = hostingViews[timelineRow.id] {
                if staleRowIds.remove(timelineRow.id) != nil {
                    hostingView.rootView = rootView(for: timelineRow)
                }
                return hostingView
            }
            let hostingView = NSHostingView(rootView: rootView(for: timelineRow))
            // The table owns the frame; the row reports its natural height itself.
            hostingView.sizingOptions = []
            // Rows scroll under the transparent titlebar. With safe areas on, the
            // row's insets change every scroll frame, which re-lays out the whole
            // row (text, fixedSize, onGeometryChange) on the main thread.
            hostingView.safeAreaRegions = []
            hostingViews[timelineRow.id] = hostingView
            return hostingView
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            BriefingTimelineRowView()
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }
    }
}

/// Lays a row out at its natural height and reports that height so the table
/// can size the row to match.
private struct BriefingTimelineRowRoot: View {
    let content: @MainActor () -> AnyView
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private final class BriefingTimelineNSTableView: NSTableView {
    /// Let hosted SwiftUI content (buttons, selectable text) take first
    /// responder instead of the table swallowing the click.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// Transparent row that never draws selection and lets hover shadows spill
/// into neighbouring rows.
private final class BriefingTimelineRowView: NSTableRowView {
    override var isOpaque: Bool { false }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {}
}
