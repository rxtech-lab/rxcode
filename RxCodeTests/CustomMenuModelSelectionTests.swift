import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class CustomMenuModelSelectionTests: XCTestCase {
    private static var retainedStores: [ThreadStore] = []

    func testSelectionSurvivesDraftAndUpdatingStoredAction() throws {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        var draft = CustomMenuDraft()
        draft.title = "Review"
        draft.actionKind = .createThread
        draft.messageTemplate = "Review this project"
        store.upsertCustomMenuItem(draft.toRecord())

        for (provider, model) in [(AgentProvider.claudeCode, "sonnet"), (.codex, "gpt-5.4"), (.acp, "client::")] {
            draft.agentProvider = provider
            draft.model = model
            store.upsertCustomMenuItem(draft.toRecord())
            let record = try XCTUnwrap(store.fetchCustomMenuItem(id: draft.id))
            let reopened = CustomMenuDraft(record: record)
            XCTAssertEqual(reopened.agentProvider, provider)
            XCTAssertEqual(reopened.model, model)
        }

        draft.agentProvider = nil
        draft.model = nil
        store.upsertCustomMenuItem(draft.toRecord())
        let record = try XCTUnwrap(store.fetchCustomMenuItem(id: draft.id))
        XCTAssertNil(record.agentProvider)
        XCTAssertNil(record.model)
    }

    func testOtherActionsDoNotStoreModelOverride() {
        var draft = CustomMenuDraft()
        draft.agentProvider = .codex
        draft.model = "gpt-5.4"
        for kind in [CustomMenuItemRecord.ActionKind.callAPI, .continueThread] {
            draft.actionKind = kind
            let record = draft.toRecord()
            XCTAssertNil(record.agentProvider)
            XCTAssertNil(record.model)
        }
    }

    func testHidingDefaultActionPreservesSiblingAndCustomActions() {
        let items = [
            MenuItem(id: "builtin.actionsMenu.project.codeReview.project-a", title: "Localized review"),
            MenuItem(id: "builtin.actionsMenu.project.commitAll.project-a", title: "Commit"),
            MenuItem(id: "builtin.customMenu.project.custom-a", title: "Localized review")
        ]
        let visible = BuiltInContextMenuAction.visibleItems(
            items, hiddenIDs: ["builtin.actionsMenu.project.codeReview"]
        )
        XCTAssertEqual(visible.map(\.id), Array(items.dropFirst()).map(\.id))
        XCTAssertEqual(BuiltInContextMenuAction.visibleItems(items, hiddenIDs: []), items)
    }

    func testVisibilityAppliesAcrossProjectsAndBranchesWithoutHidingThreadAction() {
        let items = [
            MenuItem(id: "builtin.actionsMenu.project.codeReview.project-a"),
            MenuItem(id: "builtin.actionsMenu.project.codeReview.project-b.feature.test"),
            MenuItem(id: "builtin.actionsMenu.thread.codeReview.session-a")
        ]
        XCTAssertEqual(
            BuiltInContextMenuAction.visibleItems(items, hiddenIDs: ["builtin.actionsMenu.project.codeReview"]).map(\.id),
            [items[2].id]
        )
    }
}
