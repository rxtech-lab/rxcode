import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Both levels of inspector tabs use the same pane, split, and move behavior.
struct InspectorPaneStack<Tab: Identifiable & Codable & Equatable, Item: InspectorTabTransfer, Header: View, Content: View>: View
where Tab.ID == Item.ID, Tab.ID: Codable {
    typealias Pane = InspectorPaneLayout<Tab>.Pane

    @Binding var layout: InspectorPaneLayout<Tab>
    let accessibilityIdentifier: String
    var minimumPaneHeight: CGFloat = 112
    var focusParent: () -> Void = {}
    @ViewBuilder let header: (Pane, InspectorPaneTabActions<Item>) -> Header
    @ViewBuilder let content: (Pane) -> Content

    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = InspectorTabDragState<Tab.ID>()

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(layout.panes.count)
            let idealHeight = max(0, geometry.size.height - (count - 1)) / count
            VSplitView {
                ForEach(layout.panes) { pane in
                    let splitTab = drag.tabID.flatMap { layout.canSplit($0, beside: pane.id) ? $0 : nil }
                    VStack(spacing: 0) {
                        header(pane, InspectorPaneTabActions(
                            drag: $drag,
                            move: { item, anchor in move(item, to: pane.id, before: anchor) },
                            split: { id, edge in split(id, beside: pane.id, edge: edge) }
                        ))
                        .fixedSize(horizontal: false, vertical: true)
                        content(pane)
                            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            .simultaneousGesture(TapGesture().onEnded {
                                if layout.focusedPaneID != pane.id, let selected = pane.selectedTabID {
                                    layout.select(selected)
                                }
                            })
                            // Keep native content mounted while yielding its drop area to the split targets.
                            .frame(height: splitTab == nil ? nil : 0)
                            .clipped()
                            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .overlay {
                                if let id = splitTab {
                                    VStack(spacing: 0) {
                                        ForEach(InspectorSplitEdge.allCases, id: \.self) { edge in
                                            InspectorSplitDropTarget(edge: edge) { (item: Item) in
                                                guard item.windowID == windowState.id, item.id == id else { return false }
                                                return split(id, beside: pane.id, edge: edge)
                                            }
                                        }
                                    }
                                    .transition(.identity)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, minHeight: min(minimumPaneHeight, idealHeight),
                           idealHeight: idealHeight, maxHeight: .infinity)
                    .clipped()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(accessibilityIdentifier)
                }
            }
            // A new first split should divide the available space evenly.
            // AppKit otherwise reuses divider positions from a previous pair.
            .id(layout.panes.count == 1)
        }
        .onChange(of: layout.tabIDs) { _, ids in
            if let tabID = drag.tabID, !ids.contains(tabID) { drag.finish() }
        }
    }

    private func move(_ item: Item, to paneID: UUID, before anchor: Tab.ID?) -> Bool {
        guard item.windowID == windowState.id, layout.tabIDs.contains(item.id) else { return false }
        drag.finish()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            focusParent()
            layout.move(item.id, to: paneID, before: anchor)
        }
        return true
    }

    @discardableResult
    private func split(_ id: Tab.ID, beside paneID: UUID, edge: InspectorSplitEdge) -> Bool {
        guard layout.canSplit(id, beside: paneID) else { return false }
        drag.finish()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            focusParent()
            layout.split(id, beside: paneID, edge: edge)
        }
        return true
    }
}

nonisolated protocol InspectorTabTransfer: Identifiable, Codable, Transferable {
    static var contentType: UTType { get }
    var windowID: UUID { get }
}

nonisolated extension InspectorTabTransfer {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: Self.self, contentType: contentType)
    }
}

nonisolated struct InspectorTabDrag: InspectorTabTransfer {
    let id: UUID
    let windowID: UUID
    static let contentType = UTType(exportedAs: "com.rxlab.rxcode.inspector-tab")
}

nonisolated struct InspectorDestinationDrag: InspectorTabTransfer {
    let id: InspectorMode
    let windowID: UUID
    static let contentType = UTType(exportedAs: "com.rxlab.rxcode.inspector-destination")
}

struct InspectorTabDragState<ID> {
    private var sessionID: DragSession.ID?
    private(set) var tabID: ID?

    mutating func update(_ session: DragSession, tabID: ID) {
        switch session.phase {
        case .initial, .active:
            // SwiftUI can send another update after the drop has changed the pane.
            guard session.id != sessionID else { return }
            sessionID = session.id
            self.tabID = tabID
        case .ended, .dataTransferCompleted:
            if session.id == sessionID { finish() }
        @unknown default: break
        }
    }

    mutating func finish() { tabID = nil }
}

struct InspectorPaneTabActions<Item: InspectorTabTransfer> {
    @Binding var drag: InspectorTabDragState<Item.ID>
    let move: (Item, Item.ID?) -> Bool
    let split: (Item.ID, InspectorSplitEdge) -> Void
}

struct InspectorDraggableTab<Item: InspectorTabTransfer>: ViewModifier {
    let item: Item
    let tabIDs: [Item.ID]
    let actions: InspectorPaneTabActions<Item>
    var onClose: (() -> Void)?
    @State private var isDropTargeted = false

    /// A tab dragged forward in its own strip lands after the tab under the pointer.
    private func insertionAnchor(for dragged: Item.ID?) -> Item.ID? {
        guard let dragged, let source = tabIDs.firstIndex(of: dragged),
              let target = tabIDs.firstIndex(of: item.id), source < target else { return item.id }
        return tabIDs.dropFirst(target + 1).first
    }

    func body(content: Content) -> some View {
        let dragged = actions.drag.tabID
        let insertAfter = insertionAnchor(for: dragged) != item.id
        content
            .contentShape(.dragPreview, .rect(cornerRadius: 7))
            .draggable(Item.self, item: item)
            .onDragSessionUpdated { session in actions.drag.update(session, tabID: item.id) }
            .opacity(dragged == item.id ? 0.4 : 1)
            .contextMenu {
                Button("Split Above", systemImage: "rectangle.topthird.inset.filled") { actions.split(item.id, .above) }
                    .disabled(tabIDs.count < 2)
                Button("Split Below", systemImage: "rectangle.bottomthird.inset.filled") { actions.split(item.id, .below) }
                    .disabled(tabIDs.count < 2)
                if let onClose {
                    Divider()
                    Button("Close Tab", systemImage: "xmark", action: onClose)
                }
            }
            .overlay(alignment: insertAfter ? .trailing : .leading) {
                if isDropTargeted, let dragged, dragged != item.id {
                    Capsule().fill(ClaudeTheme.accent).frame(width: 2, height: 20)
                        .offset(x: insertAfter ? 2 : -2)
                        .allowsHitTesting(false)
                }
            }
            .inspectorTabDrop(isTargeted: $isDropTargeted) { (dropped: Item) in
                actions.move(dropped, insertionAnchor(for: dropped.id))
            }
    }
}

struct InspectorTabEndDropTarget<Item: InspectorTabTransfer>: View {
    let onDrop: (Item) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isTargeted {
                    Capsule().fill(ClaudeTheme.accent).frame(width: 2, height: 20)
                        .allowsHitTesting(false)
                }
            }
            .inspectorTabDrop(isTargeted: $isTargeted, perform: onDrop)
            .accessibilityHidden(true)
    }
}

private struct InspectorSplitDropTarget<Item: InspectorTabTransfer>: View {
    let edge: InspectorSplitEdge
    let onDrop: (Item) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                shape.fill(ClaudeTheme.accent.opacity(isTargeted ? 0.20 : 0.04))
                    .overlay {
                        shape.strokeBorder(
                            ClaudeTheme.accent.opacity(isTargeted ? 1 : 0.42),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [5, 4])
                        )
                    }
                    .overlay {
                        Label {
                            Text(edge == .above ? "Split Above" : "Split Below")
                        } icon: {
                            Image(systemName: edge == .above ? "rectangle.topthird.inset.filled" : "rectangle.bottomthird.inset.filled")
                        }
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(ClaudeTheme.surfaceElevated, in: .capsule)
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
            .inspectorTabDrop(isTargeted: $isTargeted, perform: onDrop)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isTargeted)
            .accessibilityHidden(true)
    }
}

private extension View {
    func inspectorTabDrop<Item: InspectorTabTransfer>(isTargeted: Binding<Bool>, perform: @escaping (Item) -> Bool) -> some View {
        dropDestination(for: Item.self) { items, _ in
            items.first.map(perform) ?? false
        } isTargeted: {
            isTargeted.wrappedValue = $0
        }
    }
}
