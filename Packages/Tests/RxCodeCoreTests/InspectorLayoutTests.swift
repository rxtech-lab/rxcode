import Foundation
import XCTest
@testable import RxCodeCore

final class InspectorLayoutTests: XCTestCase {
    func testEveryDestinationCanSplitAndRejoinWithoutChangingToolOrBrowserSessions() throws {
        for mode in InspectorMode.allCases {
            var layout = InspectorLayout(selected: mode, tool: .run)
            let original = layout.destinations.focusedPaneID
            let browser = layout.browserID
            let tools = layout.tools

            layout.destinations.split(mode, beside: original, edge: .below)
            XCTAssertEqual(layout.destinations.panes.map(\.tabs), [InspectorMode.allCases.filter { $0 != mode }, [mode]])
            let split = layout.destinations.focusedPaneID
            XCTAssertEqual(layout.mode, mode)
            XCTAssertFalse(layout.destinations.canSplit(mode, beside: split))

            let neighbor = try XCTUnwrap(layout.destinations.panes[0].selectedTab)
            layout.mode = neighbor
            XCTAssertEqual(layout.destinations.focusedPaneID, original)
            layout.mode = mode
            XCTAssertEqual(layout.destinations.focusedPaneID, split)
            XCTAssertEqual(InspectorLayout.restore(from: try JSONEncoder().encode(layout)), layout)

            layout.destinations.move(mode, to: original, before: neighbor)
            XCTAssertEqual(layout.destinations.panes.map(\.id), [original])
            XCTAssertEqual(layout.destinations.tabIDs, Set(InspectorMode.allCases))
            XCTAssertEqual(layout.mode, mode)
            XCTAssertEqual(layout.tools, tools)
            XCTAssertEqual(layout.browserID, browser)
        }
    }

    func testReorderingAndSplittingDestinationsKeepsTheNeighborSelected() throws {
        var layout = InspectorLayout(selected: .browser)
        let original = layout.destinations.focusedPaneID
        layout.destinations.move(.preview, to: original, before: .changes)
        XCTAssertEqual(layout.destinations.panes[0].tabs, [.preview, .changes, .inspector, .browser])
        XCTAssertEqual(layout.mode, .browser)

        layout.destinations.split(.preview, beside: original, edge: .above)
        let preview = layout.destinations.focusedPaneID
        layout.destinations.split(.changes, beside: preview, edge: .below)
        let changes = layout.destinations.focusedPaneID
        XCTAssertEqual(layout.destinations.panes.compactMap(\.selectedTab), [.preview, .changes, .browser])
        layout.destinations.split(.preview, beside: original, edge: .below)
        XCTAssertEqual(layout.destinations.panes.map(\.id), [changes, original, preview])
        XCTAssertEqual(layout.destinations.focusedPaneID, preview)
    }

    func testFixedDestinationLayoutMigratesWithoutLosingNestedSplitsOrBrowserHistoryKeys() throws {
        var fixed = InspectorLayout(selected: .preview, tool: .run)
        let run = try XCTUnwrap(fixed.tools.selectedTab)
        fixed.tools.split(run.id, beside: fixed.tools.focusedPaneID, edge: .below)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixed)) as? [String: Any])
        saved.removeValue(forKey: "destinations")
        saved["review"] = "Branch"
        let oldBrowser = UUID()
        saved["previousBrowserIDs"] = [oldBrowser.uuidString]

        let restored = try XCTUnwrap(InspectorLayout.restore(from: JSONSerialization.data(withJSONObject: saved)))
        XCTAssertEqual(restored.destinations.panes.map(\.tabs), [InspectorMode.allCases])
        XCTAssertEqual(restored.mode, .preview)
        XCTAssertEqual(restored.tools, fixed.tools)
        XCTAssertEqual(restored.browserID, fixed.browserID)
        XCTAssertEqual(restored.previousBrowserIDs, [oldBrowser])
    }

    func testSavedReviewSplitsMigrateToChangesWithoutLosingPaneOrSessionIdentity() throws {
        var layout = InspectorLayout(selected: .changes, tool: .run)
        let originalPane = layout.destinations.focusedPaneID
        layout.destinations.split(.changes, beside: originalPane, edge: .above)
        let run = try XCTUnwrap(layout.tools.selectedTab)
        layout.tools.split(run.id, beside: layout.tools.focusedPaneID, edge: .below)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])
        saved["review"] = "This thread"

        let restored = try XCTUnwrap(InspectorLayout.restore(from: JSONSerialization.data(withJSONObject: saved)))
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored.mode, .changes)
        XCTAssertEqual(restored.destinations.panes.first?.selectedTab, .changes)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil(encoded["review"])
    }

    func testReorderingToolsKeepsTheCurrentTabSelected() throws {
        var layout = InspectorLayout(selected: .inspector)
        let pane = try XCTUnwrap(layout.tools.panes.first)
        let terminal = try XCTUnwrap(pane.selectedTab)
        let views = try XCTUnwrap(pane.tabs.last)

        layout.tools.move(views.id, to: pane.id, before: terminal.id)
        XCTAssertEqual(layout.tools.panes[0].tabs.map(\.tool), [.views, .terminal, .run])
        XCTAssertEqual(layout.tools.selectedTab?.id, terminal.id)
        XCTAssertEqual(layout.mode, .inspector)

        layout.tools.move(views.id, to: pane.id)
        XCTAssertEqual(layout.tools.panes[0].tabs.map(\.tool), InspectorTab.allCases)
    }

    func testMovingTheOnlyToolOutOfASplitCollapsesItsPane() throws {
        var layout = InspectorToolLayout()
        let original = try XCTUnwrap(layout.panes.first)
        let run = try XCTUnwrap(original.tabs.first { $0.tool == .run })

        layout.split(run.id, beside: original.id, edge: .above)
        XCTAssertEqual(layout.panes.count, 2)
        let split = try XCTUnwrap(layout.panes.first)
        XCTAssertEqual(split.selectedTab?.id, run.id)
        XCTAssertEqual(layout.focusedPaneID, split.id)
        XCTAssertFalse(layout.canSplit(run.id, beside: split.id))

        layout.move(run.id, to: original.id, before: original.tabs.first?.id)
        XCTAssertEqual(layout.panes.map(\.id), [original.id])
        XCTAssertEqual(layout.selectedTab?.id, run.id)
    }

    func testClosingTabsSelectsANeighborAndAllowsReopeningAnEmptyToolPane() throws {
        var layout = InspectorToolLayout(selected: .run)
        let pane = try XCTUnwrap(layout.panes.first)
        let run = try XCTUnwrap(layout.selectedTab)

        layout.close(run.id)
        XCTAssertEqual(layout.selectedTab?.tool, .views)
        for tab in layout.panes[0].tabs { layout.close(tab.id) }
        XCTAssertEqual(layout.panes.map(\.id), [pane.id])
        XCTAssertNil(layout.selectedTab)

        let reopened = layout.reveal(.run)
        XCTAssertEqual(layout.selectedTab?.id, reopened)
        XCTAssertEqual(layout.selectedTab?.tool, .run)
    }

    func testDuplicateToolTabsKeepIndependentSelectionsAndRoundTrip() throws {
        var layout = InspectorLayout(selected: .inspector, tool: .terminal)
        let pane = try XCTUnwrap(layout.tools.panes.first)
        let terminal = try XCTUnwrap(pane.selectedTab)
        let second = layout.tools.add(.terminal, to: pane.id)

        layout.tools.split(second, beside: pane.id, edge: .below)
        XCTAssertEqual(layout.tools.panes.compactMap { $0.selectedTab?.id }, [terminal.id, second])
        XCTAssertEqual(layout.tools.reveal(.terminal), second)
        layout.mode = .browser

        let saved = try JSONEncoder().encode(layout)
        XCTAssertEqual(InspectorLayout.restore(from: saved), layout)
        XCTAssertNil(InspectorLayout.restore(from: Data("{}".utf8)))
    }

    func testLegacyLayoutRestoresFixedModesAndRetainsTheBrowserSessionID() throws {
        let pane = UUID()
        let toolsTab = UUID()
        let browser = UUID()
        let review = UUID()
        let legacy = """
            {"focusedPaneID":"\(pane)","panes":[{"id":"\(pane)","selectedTabID":"\(toolsTab)","tabs":[
            {"id":"\(toolsTab)","mode":"Inspector","tool":"Views"},
            {"id":"\(browser)","mode":"Browser"},
            {"id":"\(review)","mode":"Review","review":"Changes"}
            ]}]}
            """

        let layout = try XCTUnwrap(InspectorLayout.restore(from: Data(legacy.utf8)))
        XCTAssertEqual(layout.mode, .inspector)
        XCTAssertEqual(layout.browserID, browser)
        XCTAssertEqual(layout.tools.selectedTab?.tool, .views)
        XCTAssertEqual(layout.tools.panes[0].tabs.map(\.tool), InspectorTab.allCases)
    }
}
