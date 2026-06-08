import XCTest
import RxCodeCore
@testable import RxCode

/// Verifies that session-end lifecycle hooks (code review, commit/push, send
/// message, user stop hooks) are centrally suppressed for *planning* turns —
/// plan mode or an undecided `ExitPlanMode` plan — across both the before- and
/// after-session-end dispatch paths, while ordinary turns still dispatch.
@MainActor
final class PlanModeHookSuppressionTests: XCTestCase {

    /// Records whether the session-end dispatch reached the registered hooks.
    private final class SpyStopHook: Hook {
        let hookID = "test.spyStop"
        private(set) var beforeCalled = false
        private(set) var afterCalled = false

        func beforeSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
            beforeCalled = true
            return .ignored
        }

        func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
            afterCalled = true
            return .ignored
        }
    }

    private var appState: AppState!
    private var spy: SpyStopHook!
    /// A manager wired to the real controller but holding only the spy, so the
    /// assertions observe the suppression guard without the built-in hooks'
    /// side effects (notifications, disk reads).
    private var manager: HookManager!

    override func setUp() async throws {
        appState = AppState(startBackgroundServices: false)
        spy = SpyStopHook()
        manager = HookManager(controller: appState.hookController)
        manager.register(spy)
    }

    override func tearDown() async throws {
        appState = nil
        spy = nil
        manager = nil
    }

    // MARK: - Helpers

    private func makeProject(_ name: String = "P") -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())", gitHubRepo: nil)
    }

    private func makePayload(sessionKey: String, reason: SessionEndReason = .completed) -> SessionEndPayload {
        SessionEndPayload(
            project: makeProject(),
            sessionKey: sessionKey,
            sessionId: sessionKey,
            reason: reason,
            turnDidError: false,
            lastAssistantText: ""
        )
    }

    private func exitPlanMessage(decisionResult: String? = nil, toolId: String = "plan-1") -> ChatMessage {
        let toolCall = ToolCall(id: toolId, name: "ExitPlanMode", result: decisionResult)
        return ChatMessage(role: .assistant, blocks: [.toolCall(toolCall)])
    }

    // MARK: - Plan mode

    func testPlanMode_suppressesBeforeAndAfterSessionEndHooks() async {
        let key = "plan-mode-session"
        var state = SessionStreamState()
        state.planMode = true
        appState.sessionStates[key] = state

        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: key))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: key))

        XCTAssertFalse(spy.beforeCalled, "before-session-end hooks must not run in plan mode")
        XCTAssertFalse(spy.afterCalled, "after-session-end hooks must not run in plan mode")
    }

    func testPlanMode_suppressesOnCancellationPath() async {
        let key = "plan-mode-cancel"
        var state = SessionStreamState()
        state.planMode = true
        appState.sessionStates[key] = state

        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: key, reason: .cancelled))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: key, reason: .cancelled))

        XCTAssertFalse(spy.beforeCalled, "plan-mode cancellation must not run stop hooks")
        XCTAssertFalse(spy.afterCalled, "plan-mode cancellation must not run stop hooks")
    }

    // MARK: - Pending / ready plan

    func testPendingExitPlan_suppressesHooks() async {
        let key = "ready-plan-session"
        var state = SessionStreamState()
        state.messages = [exitPlanMessage(decisionResult: nil)] // emitted but undecided
        appState.sessionStates[key] = state

        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: key))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: key))

        XCTAssertFalse(spy.beforeCalled, "an undecided ExitPlanMode plan must suppress stop hooks")
        XCTAssertFalse(spy.afterCalled, "an undecided ExitPlanMode plan must suppress stop hooks")
    }

    func testPendingExitPlan_viaSidecarDecision_doesNotSuppress() async {
        // Plan decided through the planDecisionSummaries sidecar (the CLI reload
        // path) — hooks should resume.
        let key = "sidecar-decided-session"
        var state = SessionStreamState()
        state.messages = [exitPlanMessage(decisionResult: nil, toolId: "plan-x")]
        state.planDecisionSummaries = ["plan-x": "Accepted with Ask"]
        appState.sessionStates[key] = state

        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: key))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: key))

        XCTAssertTrue(spy.beforeCalled, "a sidecar-decided plan should no longer suppress hooks")
        XCTAssertTrue(spy.afterCalled, "a sidecar-decided plan should no longer suppress hooks")
    }

    // MARK: - Control cases (must still dispatch)

    func testDecidedPlan_doesNotSuppress() async {
        let key = "decided-plan-session"
        var state = SessionStreamState()
        state.messages = [exitPlanMessage(decisionResult: "Accepted with Ask")]
        appState.sessionStates[key] = state

        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: key))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: key))

        XCTAssertTrue(spy.beforeCalled, "an accepted plan should dispatch stop hooks")
        XCTAssertTrue(spy.afterCalled, "an accepted plan should dispatch stop hooks")
    }

    func testOrdinaryCompletion_dispatchesHooks() async {
        let key = "ordinary-session"
        var state = SessionStreamState()
        state.messages = [ChatMessage(role: .assistant, content: "done")]
        appState.sessionStates[key] = state

        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: key))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: key))

        XCTAssertTrue(spy.beforeCalled, "a normal completion must dispatch stop hooks")
        XCTAssertTrue(spy.afterCalled, "a normal completion must dispatch stop hooks")
    }

    func testNoSessionState_dispatchesHooks() async {
        // No state recorded for the key → not a planning turn → hooks run.
        _ = await manager.dispatchBeforeSessionEnd(makePayload(sessionKey: "unknown"))
        _ = await manager.dispatchAfterSessionEnd(makePayload(sessionKey: "unknown"))

        XCTAssertTrue(spy.beforeCalled)
        XCTAssertTrue(spy.afterCalled)
    }
}
