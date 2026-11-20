import Foundation

/// The window's inspector panes and the tool tabs nested inside the Tools destination.
public struct InspectorLayout: Codable, Equatable {
    public var destinations: InspectorDestinationLayout
    public var review: InspectorReviewTab
    public var tools: InspectorToolLayout
    public private(set) var browserID = UUID()
    public private(set) var previousBrowserIDs: [UUID] = []

    /// Revealing a destination selects it in the pane that already owns it.
    public var mode: InspectorMode {
        get { destinations.selectedTab ?? .review }
        set { destinations.select(newValue) }
    }

    public init(selected mode: InspectorMode = .review, tool: InspectorTab = .terminal, review: InspectorReviewTab = .thisThread) {
        destinations = InspectorDestinationLayout(selected: mode)
        self.review = review
        tools = InspectorToolLayout(selected: tool)
    }

    private enum CodingKeys: CodingKey {
        case mode, destinations, review, tools, browserID, previousBrowserIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        review = try values.decode(InspectorReviewTab.self, forKey: .review)
        tools = try values.decode(InspectorToolLayout.self, forKey: .tools)
        browserID = try values.decode(UUID.self, forKey: .browserID)
        previousBrowserIDs = try values.decodeIfPresent([UUID].self, forKey: .previousBrowserIDs) ?? []
        if let saved = try? values.decode(InspectorDestinationLayout.self, forKey: .destinations),
           saved.isValid, saved.tabIDs == Set(InspectorMode.allCases) {
            destinations = saved
        } else {
            destinations = InspectorDestinationLayout(selected: try values.decode(InspectorMode.self, forKey: .mode))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(destinations, forKey: .destinations)
        try values.encode(review, forKey: .review)
        try values.encode(tools, forKey: .tools)
        try values.encode(browserID, forKey: .browserID)
        try values.encode(previousBrowserIDs, forKey: .previousBrowserIDs)
    }

    public static func restore(from data: Data) -> Self? {
        let decoder = JSONDecoder()
        if let layout = try? decoder.decode(Self.self, from: data), layout.tools.isValid {
            return layout
        }
        guard let legacy = try? decoder.decode(LegacyInspectorLayout.self, from: data) else { return nil }
        var layout = Self(
            selected: legacy.selected?.mode ?? .review,
            tool: legacy.preferred(.inspector)?.tool ?? .terminal,
            review: legacy.preferred(.review)?.review ?? .thisThread
        )
        if let browser = legacy.preferred(.browser) {
            let others = legacy.panes.flatMap(\.tabs).filter { $0.mode == .browser && $0.id != browser.id }
            if others.isEmpty {
                layout.browserID = browser.id
            } else {
                // A new session key makes consolidating the old browser panes idempotent.
                layout.previousBrowserIDs = [browser.id] + others.map(\.id)
            }
        }
        return layout
    }
}

private struct LegacyInspectorLayout: Decodable {
    struct Tab: Decodable {
        let id: UUID
        let mode: InspectorMode
        let tool: InspectorTab?
        let review: InspectorReviewTab?
    }

    struct Pane: Decodable {
        let id: UUID
        let tabs: [Tab]
        let selectedTabID: UUID?
        var selected: Tab? { tabs.first { $0.id == selectedTabID } }
    }

    let panes: [Pane]
    let focusedPaneID: UUID
    var selected: Tab? { panes.first { $0.id == focusedPaneID }?.selected }

    func preferred(_ mode: InspectorMode) -> Tab? {
        if let selected, selected.mode == mode { return selected }
        return panes.compactMap(\.selected).first { $0.mode == mode }
            ?? panes.lazy.flatMap(\.tabs).first { $0.mode == mode }
    }
}

public typealias InspectorDestinationLayout = InspectorPaneLayout<InspectorMode>
public typealias InspectorToolLayout = InspectorPaneLayout<InspectorToolTab>

public struct InspectorToolTab: Codable, Equatable, Identifiable {
    public let id: UUID
    public let tool: InspectorTab

    fileprivate init(tool: InspectorTab) {
        id = UUID()
        self.tool = tool
    }
}

public enum InspectorSplitEdge: CaseIterable {
    case above, below
}

/// Ordered, vertically split panes with a selected tab in each pane.
public struct InspectorPaneLayout<Item: Identifiable & Codable & Equatable>: Codable, Equatable where Item.ID: Codable {
    public typealias Tab = Item
    public typealias SplitEdge = InspectorSplitEdge

    public struct Pane: Codable, Equatable, Identifiable {
        public let id: UUID
        public fileprivate(set) var tabs: [Tab]
        public fileprivate(set) var selectedTabID: Tab.ID?
        fileprivate var previousTabID: Tab.ID?

        public var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

        fileprivate init(tabs: [Tab], selectedTabID: Tab.ID?) {
            id = UUID()
            self.tabs = tabs
            self.selectedTabID = selectedTabID
        }

        fileprivate mutating func select(_ id: Tab.ID) {
            guard selectedTabID != id else { return }
            previousTabID = selectedTabID
            selectedTabID = id
        }

        fileprivate mutating func removeTab(at index: Int) -> Tab {
            let tab = tabs.remove(at: index)
            if previousTabID == tab.id { previousTabID = nil }
            if selectedTabID == tab.id {
                selectedTabID = previousTabID ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id)
                previousTabID = nil
            }
            return tab
        }
    }

    public private(set) var panes: [Pane]
    public private(set) var focusedPaneID: UUID
    public var selectedTab: Tab? { panes.first { $0.id == focusedPaneID }?.selectedTab }
    public var tabIDs: Set<Tab.ID> { Set(panes.flatMap { $0.tabs.map(\.id) }) }

    private init(tabs: [Tab], selectedTabID: Tab.ID?) {
        let pane = Pane(tabs: tabs, selectedTabID: selectedTabID)
        panes = [pane]
        focusedPaneID = pane.id
    }

    fileprivate var isValid: Bool {
        guard panes.contains(where: { $0.id == focusedPaneID }),
              Set(panes.map(\.id)).count == panes.count,
              panes.allSatisfy({ pane in
                  if let previous = pane.previousTabID,
                     previous == pane.selectedTabID || !pane.tabs.contains(where: { $0.id == previous }) { return false }
                  return pane.selectedTab != nil || (panes.count == 1 && pane.tabs.isEmpty && pane.selectedTabID == nil)
              }) else { return false }
        return tabIDs.count == panes.reduce(0) { $0 + $1.tabs.count }
    }

    public mutating func select(_ tabID: Tab.ID) {
        guard let source = location(of: tabID) else { return }
        panes[source.pane].select(tabID)
        focusedPaneID = panes[source.pane].id
    }

    /// Inserts before the anchor, or at the end when the strip is empty or has room after its last tab.
    public mutating func move(_ tabID: Tab.ID, to paneID: UUID, before anchor: Tab.ID? = nil) {
        guard tabID != anchor, let source = location(of: tabID),
              let destination = panes.firstIndex(where: { $0.id == paneID }),
              anchor == nil || panes[destination].tabs.contains(where: { $0.id == anchor }) else { return }
        let samePane = source.pane == destination
        let tab = samePane ? panes[source.pane].tabs.remove(at: source.tab) : panes[source.pane].removeTab(at: source.tab)
        let index = panes[destination].tabs.firstIndex { $0.id == anchor } ?? panes[destination].tabs.endIndex
        panes[destination].tabs.insert(tab, at: index)
        if !samePane {
            panes[destination].select(tabID)
            focusedPaneID = paneID
            removePaneIfEmpty(at: source.pane)
        }
    }

    public func canSplit(_ tabID: Tab.ID, beside paneID: UUID) -> Bool {
        guard let source = location(of: tabID), panes.contains(where: { $0.id == paneID }) else { return false }
        return panes[source.pane].id != paneID || panes[source.pane].tabs.count > 1
    }

    public mutating func split(_ tabID: Tab.ID, beside paneID: UUID, edge: SplitEdge) {
        guard canSplit(tabID, beside: paneID), let source = location(of: tabID),
              let destination = panes.firstIndex(where: { $0.id == paneID }) else { return }
        var insertion = edge == .above ? destination : destination + 1
        let pane: Pane
        if panes[source.pane].tabs.count == 1 {
            // Moving the whole pane keeps its native content and divider identity.
            pane = panes.remove(at: source.pane)
            if source.pane < insertion { insertion -= 1 }
        } else {
            let tab = panes[source.pane].removeTab(at: source.tab)
            pane = Pane(tabs: [tab], selectedTabID: tabID)
        }
        panes.insert(pane, at: insertion)
        focusedPaneID = pane.id
    }

    private func location(of tabID: Tab.ID) -> (pane: Int, tab: Int)? {
        for (pane, item) in panes.enumerated() {
            if let tab = item.tabs.firstIndex(where: { $0.id == tabID }) { return (pane, tab) }
        }
        return nil
    }

    private mutating func removePaneIfEmpty(at index: Int) {
        guard panes.count > 1, panes[index].tabs.isEmpty else { return }
        let pane = panes.remove(at: index)
        if focusedPaneID == pane.id { focusedPaneID = panes[min(index, panes.count - 1)].id }
    }
}

extension InspectorPaneLayout where Item == InspectorMode {
    public init(selected mode: InspectorMode) {
        self.init(tabs: InspectorMode.allCases, selectedTabID: mode)
    }
}

extension InspectorPaneLayout where Item == InspectorToolTab {
    public init(selected tool: InspectorTab = .terminal) {
        let tabs = InspectorTab.allCases.map(Tab.init(tool:))
        self.init(tabs: tabs, selectedTabID: tabs.first { $0.tool == tool }?.id)
    }

    @discardableResult
    public mutating func reveal(_ tool: InspectorTab) -> UUID {
        let focused = panes.first { $0.id == focusedPaneID }
        let existing = selectedTab.flatMap { $0.tool == tool ? $0 : nil }
            ?? panes.compactMap(\.selectedTab).first { $0.tool == tool }
            ?? focused?.tabs.first { $0.tool == tool }
            ?? panes.lazy.flatMap(\.tabs).first { $0.tool == tool }
        if let existing {
            select(existing.id)
            return existing.id
        }
        return add(tool, to: focusedPaneID)
    }

    @discardableResult
    public mutating func add(_ tool: InspectorTab, to paneID: UUID) -> UUID {
        let index = panes.firstIndex { $0.id == paneID } ?? panes.firstIndex { $0.id == focusedPaneID } ?? 0
        let tab = Tab(tool: tool)
        panes[index].tabs.append(tab)
        panes[index].select(tab.id)
        focusedPaneID = panes[index].id
        return tab.id
    }

    public mutating func close(_ tabID: UUID) {
        guard let source = location(of: tabID) else { return }
        _ = panes[source.pane].removeTab(at: source.tab)
        removePaneIfEmpty(at: source.pane)
    }
}
