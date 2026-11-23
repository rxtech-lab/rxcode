import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class MobileComputerUseConfirmationTests: XCTestCase {
    private func enqueue(
        _ id: String, session: String, tool: String = "mcp__cua_repl__js", in app: AppState
    ) async throws -> (PermissionRequest, Task<PermissionDecision, Never>) {
        let server = app.permission
        let (token, stream) = await server.subscribe()
        let decision = Task {
            await server.requestDecision(toolUseId: id, sessionId: session, toolName: tool, toolInput: [:], mode: .default)
        }
        let received = await stream.first { @Sendable request in
            request.id == id && request.sessionId == session
        }
        let request = try XCTUnwrap(received)
        await server.unsubscribe(token: token)
        app.queuePermissionRequest(request)
        return (request, decision)
    }

    func testMobileGrantResolvesComputerUseOnlyInItsSession() async throws {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        app.registerLiveWindow(window)
        let ide = AgentConfirmation(request: .init(title: "Continue?"), sessionKey: "second", projectId: nil)
        app.agentPrompts.confirmations = [ide]
        let (first, firstDecision) = try await enqueue("one", session: "pending-first", in: app)
        let (sibling, siblingDecision) = try await enqueue("two", session: "pending-first", tool: "mcp__cua__click", in: app)
        let (other, otherDecision) = try await enqueue("three", session: "second", in: app)
        let (edit, editDecision) = try await enqueue("edit", session: "second", tool: "Edit", in: app)
        app.sessionIdRedirect["pending-first"] = "first"
        let projectID = UUID()
        app.allSessionSummaries = [.init(id: "first", projectId: projectID, title: "First",
                                         createdAt: Date(), updatedAt: Date(), isPinned: false, agentProvider: .codex)]

        let prompts = app.mobilePendingConfirmationPayloads()
        let prompt = try XCTUnwrap(prompts.first { $0.id == first.promptID.uuidString })
        XCTAssertEqual(prompt.sessionID, "first")
        XCTAssertEqual(prompt.projectID, projectID)
        XCTAssertEqual(prompt.confirmLabel, "Confirm for This Session")
        XCTAssertEqual(prompt.cancelLabel, "Reject")
        XCTAssertEqual(Set(prompts.map(\.id)), Set([ide.id, first.promptID, sibling.promptID, other.promptID].map(\.uuidString)))
        let anotherWindow = WindowState()
        app.registerLiveWindow(anotherWindow)

        await app.handleMobileConfirmationDecision(id: first.promptID, confirmed: true)
        await app.handleMobileConfirmationDecision(id: first.promptID, confirmed: false)
        await app.handleMobileConfirmationDecision(id: edit.promptID, confirmed: true)
        XCTAssertEqual(Set(app.mobilePendingConfirmationPayloads().map(\.id)), [ide.id.uuidString, other.promptID.uuidString])
        for view in [window, anotherWindow] {
            XCTAssertEqual(Set(view.pendingPermissions.map(\.id)), [other.id, edit.id])
        }
        await app.permission.stop()
        let outcomes = await [firstDecision.value, siblingDecision.value, otherDecision.value, editDecision.value]
        XCTAssertEqual(outcomes, [.allow, .allow, .deny, .deny])
    }

    func testRejectionAndLateMobileDecisionsCannotGrantAReusedToolID() async throws {
        let app = AppState(startBackgroundServices: false)
        let (first, firstDecision) = try await enqueue("reused", session: "one", in: app)
        await app.handleMobileConfirmationDecision(id: first.promptID, confirmed: false)
        XCTAssertTrue(app.mobilePendingConfirmationPayloads().isEmpty)
        let (fresh, freshDecision) = try await enqueue(first.id, session: "one", in: app)
        XCTAssertNotEqual(first.promptID, fresh.promptID)
        await app.handleMobileConfirmationDecision(id: first.promptID, confirmed: true)
        await app.respondToPermission(first, decision: .allowSessionTool)
        XCTAssertEqual(app.mobilePendingConfirmationPayloads().map(\.id), [fresh.promptID.uuidString])
        await app.respondToPermission(fresh, decision: .deny)
        XCTAssertTrue(app.mobilePendingConfirmationPayloads().isEmpty)
        let outcomes = await [firstDecision.value, freshDecision.value]
        XCTAssertEqual(outcomes, [.deny, .deny])
    }

    func testTurnCancellationRetractsAHeadlessRequestAfterSessionRename() async throws {
        let app = AppState()
        let server = app.permission
        let decision = Task {
            await server.requestDecision(toolUseId: "cancelled", sessionId: "pending-turn",
                                         toolName: "mcp__cua__click", toolInput: [:], mode: .auto)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while app.mobilePendingConfirmationPayloads().isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prompt = try XCTUnwrap(app.mobilePendingConfirmationPayloads().first)
        app.sessionIdRedirect["pending-turn"] = "resumed-turn"
        let window = WindowState()
        window.currentSessionId = "resumed-turn"
        await app.cancelStreaming(in: window, fireStopHooks: false)
        XCTAssertTrue(app.mobilePendingConfirmationPayloads().isEmpty)
        let id = try XCTUnwrap(UUID(uuidString: prompt.id))
        await app.handleMobileConfirmationDecision(id: id, confirmed: true)
        let outcome = await decision.value
        XCTAssertEqual(outcome, .deny)
    }
}
