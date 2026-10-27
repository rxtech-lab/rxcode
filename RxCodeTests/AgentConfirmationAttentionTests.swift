import RxCodeCore
import SwiftUI
import XCTest
@testable import RxCode

@MainActor
final class AgentConfirmationAttentionTests: XCTestCase {
    func testConfirmationQueuesStayWithTheirOriginalThreadAfterSessionRename() {
        let app = AppState(startBackgroundServices: false)
        let project = UUID()
        let first = AgentConfirmation(request: .init(title: "First"), sessionKey: "pending-a", projectId: project)
        let other = AgentConfirmation(request: .init(title: "Other"), sessionKey: "b", projectId: project)
        app.agentPrompts.confirmations = [first, other]
        app.sessionIdRedirect = ["pending-a": "a", "a": "a-renamed"]
        app.setAgentConfirmationMinimized(id: first.id, minimized: true)

        XCTAssertEqual(app.agentConfirmations(forSession: "a-renamed").map(\.id), [first.id])
        XCTAssertTrue(app.agentConfirmations(forSession: "pending-a").first?.isMinimized == true)
        XCTAssertEqual(app.agentConfirmations(forSession: "b").map(\.id), [other.id])
        XCTAssertFalse(app.agentConfirmations(forSession: "b").first?.isMinimized ?? true)
        XCTAssertTrue(app.agentConfirmations(forSession: "unrelated").isEmpty)
    }

    func testAttentionAggregatesOnlyTheOwningProjectAndClearsWhenHandled() {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        let a = Project(name: "A", path: "/tmp/a")
        let b = Project(name: "B", path: "/tmp/b")
        app.allSessionSummaries = [summary("a", project: a.id), summary("b", project: b.id)]
        app.sessionIdRedirect["pending-a"] = "a"
        window.pendingPermissions = [permission("pa", session: "pending-a"), permission("pb", session: "b")]
        app.agentPrompts.confirmations = [
            AgentConfirmation(request: .init(title: "Confirm A"), sessionKey: "pending-a", projectId: a.id),
        ]
        app.hookBanners[.newProject] = [
            HookBannerItem(id: "setup-a", position: .aboveInputBox, projectId: a.id, content: AnyView(EmptyView())),
            HookBannerItem(id: "setup-b", position: .aboveInputBox, projectId: b.id, content: AnyView(EmptyView())),
        ]

        XCTAssertEqual(app.threadAttention(sessionKey: "a", in: window), PendingAttention(permissions: 1, confirmations: 1))
        XCTAssertEqual(app.threadAttention(sessionKey: "b", in: window), PendingAttention(permissions: 1))
        XCTAssertEqual(app.projectAttention(projectId: a.id, in: window), PendingAttention(permissions: 1, setups: 1, confirmations: 1))
        XCTAssertEqual(app.projectAttention(projectId: b.id, in: window), PendingAttention(permissions: 1, setups: 1))

        window.pendingPermissions.removeAll { $0.id == "pa" }
        app.agentPrompts.confirmations.removeAll()
        app.hookBanners[.newProject]?.removeAll { $0.id == "setup-a" }
        XCTAssertEqual(app.projectAttention(projectId: a.id, in: window).count, 0)
        XCTAssertEqual(app.projectAttention(projectId: b.id, in: window).count, 2)
    }

    func testNewThreadAndGlobalChatAreBadgedWithoutPersistedSummary() {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        window.selectedProject = app.globalChatProject
        let key = window.newSessionKey
        window.pendingPermissions = [permission("new", session: key)]
        app.agentPrompts.confirmations = [
            AgentConfirmation(request: .init(title: "Confirm"), sessionKey: key, projectId: Project.globalChatID),
        ]
        XCTAssertEqual(app.projectAttention(projectId: Project.globalChatID, in: window).count, 2)
        XCTAssertEqual(app.projectAttention(projectId: UUID(), in: window).count, 0)
        XCTAssertEqual(app.windowAttention(in: window).count, 2)
    }

    func testMinimizingPreservesTheWaitingDecision() async {
        let app = AppState(startBackgroundServices: false)
        let item = AgentConfirmation(request: .init(title: "Confirm"), sessionKey: "a", projectId: nil)
        let confirmed = await withCheckedContinuation { continuation in
            app.agentPrompts.confirmations = [item]
            app.agentPrompts.continuations.byId[item.id] = continuation
            app.setAgentConfirmationMinimized(id: item.id, minimized: true)
            XCTAssertNotNil(app.agentPrompts.continuations.byId[item.id])
            XCTAssertEqual(app.agentConfirmations(forSession: "a").count, 1)
            app.setAgentConfirmationMinimized(id: item.id, minimized: false)
            XCTAssertNotNil(app.agentPrompts.continuations.byId[item.id])
            app.resolveAgentConfirmation(id: item.id, confirmed: true)
            app.resolveAgentConfirmation(id: item.id, confirmed: false)
        }
        XCTAssertTrue(confirmed)
        XCTAssertTrue(app.agentConfirmations(forSession: "a").isEmpty)
        XCTAssertTrue(app.agentPrompts.continuations.byId.isEmpty)
    }

    private func permission(_ id: String, session: String) -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", toolInput: [:], runToken: id, sessionId: session)
    }

    private func summary(_ id: String, project: UUID) -> ChatSession.Summary {
        ChatSession.Summary(id: id, projectId: project, title: id,
                            createdAt: Date(), updatedAt: Date(), isPinned: false, agentProvider: .claudeCode)
    }
}
