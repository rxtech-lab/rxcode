import XCTest
import RxCodeCore
@testable import RxCode

/// Regression tests for the cross-project `ide__send_to_thread` freeze.
///
/// What the bug looked like: while one project's `processStream` was mid-turn
/// (mid-tool-call, mid-stream pause), a second concurrent `sendCrossProject`
/// for a different project would never see its `processStream` make progress —
/// the receiver thread sat at `isStreaming=true` with no assistant tokens until
/// the sender was cancelled. Two separate root causes were fixed:
///
///   1. `awaitStreamCompletion` polled MainActor every 100 ms, starving the
///      second stream's `for await event in stream` loop. (Now event-driven
///      via `StreamCompletionWaiter`.)
///   2. The cross-project MCP reply returned `pending-<streamId>` instead of
///      the CLI's real `session_id`, so the calling agent couldn't follow up
///      with `get_thread_messages`. (Now blocks on `awaitSessionRename`.)
///
/// These tests substitute a `MockAgentBackend` for the real Claude/Codex/ACP
/// services via `appState.agentBackendOverrides`, so the production CLI spawn
/// + pipe-reader path isn't exercised — that's covered by the prod runtime
/// log artefacts and the readabilityHandler swap. The orchestration layer
/// (sendPrompt → processStream → waiters) is what these tests exercise.
@MainActor
final class CrossProjectSendConcurrencyTests: XCTestCase {

    private var appState: AppState!
    private var mockBackend: MockAgentBackend!
    private var defaultsSnapshot: [String: Any?] = [:]

    override func setUp() async throws {
        // Snapshot the UserDefaults keys AppState seeds itself from, then pin
        // a known provider so a stale value from a previous run (e.g. `.codex`
        // from another test or a manual launch) doesn't route the test's
        // backend dispatch around the mock and into a half-initialised real
        // service that emits `.result(isError=true)`.
        defaultsSnapshot = [
            "selectedAgentProvider": UserDefaults.standard.object(forKey: "selectedAgentProvider"),
            "selectedModel": UserDefaults.standard.object(forKey: "selectedModel"),
        ]
        UserDefaults.standard.set("claudeCode", forKey: "selectedAgentProvider")

        appState = AppState(startBackgroundServices: false)
        appState.selectedAgentProvider = .claudeCode

        mockBackend = MockAgentBackend(provider: .claudeCode)
        // Register the mock for every provider so the test isn't sensitive to
        // which provider `effectiveModelSelection` happens to resolve.
        appState.agentBackendOverrides[.claudeCode] = mockBackend
        appState.agentBackendOverrides[.codex] = mockBackend
        appState.agentBackendOverrides[.acp] = mockBackend
    }

    override func tearDown() async throws {
        // Cancel anything still streaming so child Tasks don't outlive the test.
        for key in appState.sessionStates.keys where appState.sessionStates[key]?.isStreaming == true {
            appState.sessionStates[key]?.streamTask?.cancel()
            appState.sessionStates[key]?.flushTask?.cancel()
        }
        mockBackend = nil
        appState = nil

        for (key, value) in defaultsSnapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Real-sid resolution (PR #60 second commit)

    /// `sendCrossProject` must wait for the CLI's `.system init` event before
    /// returning, so the calling agent never sees a `pending-<UUID>` thread
    /// id in the MCP reply.
    func testCrossProjectSendReturnsRealSessionIdNotPendingPlaceholder() async throws {
        let project = makeProject("alpha")
        appState.projects = [project]
        let realSid = "real-cli-sid-\(UUID().uuidString)"

        await mockBackend.enqueueScript(
            [
                .systemInit(sessionId: realSid, delay: 0.05),
                .assistantText("hello back", delay: 0.05),
                .result(sessionId: realSid, delay: 0.05),
            ],
            forCwd: project.path
        )

        let result = try await appState.sendCrossProject(
            projectId: project.id,
            threadId: nil,
            prompt: "ping",
            agentProvider: .claudeCode,
            waitForResponse: true,
            timeoutSeconds: 10
        )

        XCTAssertEqual(result.threadId, realSid, "MCP reply must carry the real session_id, not pending-…")
        XCTAssertFalse(result.threadId.hasPrefix("pending-"), "threadId still starts with pending-: \(result.threadId)")
        XCTAssertTrue(result.done, "wait_for_response=true should return done=true on success")
        XCTAssertNil(result.error, "unexpected error: \(result.error ?? "")")
    }

    // MARK: - Concurrent-stream progress (the original freeze)

    /// While project A's stream is paused mid-turn, a second `sendCrossProject`
    /// for project B must still make progress and complete. Pre-fix this would
    /// hang for the full duration of A's pause, because `awaitStreamCompletion`'s
    /// 100 ms MainActor poll starved B's for-await.
    func testSecondCrossProjectSendCompletesWhileFirstIsPausedMidStream() async throws {
        let projectA = makeProject("alpha")
        let projectB = makeProject("beta")
        appState.projects = [projectA, projectB]

        let sidA = "sid-A-\(UUID().uuidString)"
        let sidB = "sid-B-\(UUID().uuidString)"

        // A: emit init, then pause 3s, then finish. Long enough that any
        // accidental serialization between streams shows up as a B timeout.
        await mockBackend.enqueueScript(
            [
                .systemInit(sessionId: sidA, delay: 0.05),
                .assistantText("A starting", delay: 0.05),
                .result(sessionId: sidA, delay: 3.0),
            ],
            forCwd: projectA.path
        )

        // B: completes quickly — total roughly 150 ms.
        await mockBackend.enqueueScript(
            [
                .systemInit(sessionId: sidB, delay: 0.05),
                .assistantText("B done", delay: 0.05),
                .result(sessionId: sidB, delay: 0.05),
            ],
            forCwd: projectB.path
        )

        // Kick off A in the background (don't await — A intentionally pauses).
        let aState = appState!
        let sendATask = Task { @MainActor in
            _ = try? await aState.sendCrossProject(
                projectId: projectA.id,
                threadId: nil,
                prompt: "long-running",
                agentProvider: .claudeCode,
                waitForResponse: false,
                timeoutSeconds: 30
            )
        }

        // Wait briefly so A has entered its stream + emitted its first event.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(
            appState.sessionStates.values.contains(where: { $0.isStreaming }),
            "A's stream should be active before launching B"
        )

        // Now send to B. It must complete fast even though A is paused.
        let bStart = Date()
        let resultB = try await appState.sendCrossProject(
            projectId: projectB.id,
            threadId: nil,
            prompt: "should-not-be-blocked",
            agentProvider: .claudeCode,
            waitForResponse: true,
            timeoutSeconds: 5
        )
        let bElapsed = Date().timeIntervalSince(bStart)

        XCTAssertTrue(resultB.done, "B must complete while A is paused (got error: \(resultB.error ?? "nil"))")
        XCTAssertEqual(resultB.threadId, sidB)
        XCTAssertLessThan(
            bElapsed, 2.0,
            "B took \(bElapsed)s — should be ~0.15s if not serialized behind A's 3s pause"
        )

        // Let A finish so the test tears down cleanly.
        _ = await sendATask.value
    }

    // MARK: - Event-driven completion handoff

    /// `recordStreamCompletion` must immediately resume a pending
    /// `awaitStreamCompletion` waiter — no polling sleep in between.
    func testRecordStreamCompletionResumesAwaiterImmediately() async throws {
        let streamId = UUID()
        let sessionId = "session-xyz"
        let expectedText = "done"
        let appStateRef = appState!

        let waiterTask = Task { @MainActor in
            await appStateRef.awaitStreamCompletion(streamId: streamId, timeout: 5)
        }

        // Wait a beat so the waiter is parked on its continuation, then record.
        try await Task.sleep(nanoseconds: 50_000_000)
        let startedAt = Date()
        appState.recordStreamCompletion(
            streamId: streamId,
            sessionId: sessionId,
            assistantText: expectedText,
            error: nil
        )

        let completionOpt = await waiterTask.value
        let completion = try XCTUnwrap(completionOpt)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(completion.sessionId, sessionId)
        XCTAssertEqual(completion.assistantText, expectedText)
        XCTAssertNil(completion.error)
        // Budget is generous because the measured time is dominated by MainActor
        // scheduling latency, which spikes well past 50 ms on loaded CI runners.
        // 0.5 s still catches the original regression class (poll-based waits
        // and multi-second stream starvation) without flaking.
        XCTAssertLessThan(
            elapsed, 0.5,
            "awaitStreamCompletion took \(elapsed)s after record() — should be near-instant via continuation handoff"
        )
    }

    /// Symmetric test for the session-id rename waiter: `applySessionIdRedirect`
    /// must wake a pending `awaitSessionRename` caller immediately, not on a
    /// poll cycle.
    func testApplySessionIdRedirectResumesRenameWaiterImmediately() async throws {
        let pendingKey = "pending-\(UUID().uuidString)"
        let realSid = "real-\(UUID().uuidString)"
        let appStateRef = appState!

        let waiterTask = Task { @MainActor in
            await appStateRef.awaitSessionRename(pendingKey: pendingKey, timeout: 5)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let startedAt = Date()
        appState.applySessionIdRedirect(from: pendingKey, to: realSid)

        let resolvedOpt = await waiterTask.value
        let resolved = try XCTUnwrap(resolvedOpt)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(resolved, realSid)
        // See testRecordStreamCompletionResumesAwaiterImmediately for why the
        // budget is 0.5 s: MainActor scheduling latency dominates on busy CI.
        XCTAssertLessThan(elapsed, 0.5, "session-rename waiter took \(elapsed)s — should be near-instant")
    }

    // MARK: - Provider-native session ids

    /// When a user switches providers inside an existing thread, the new provider
    /// reports its own native session id. That id must be recorded for resume, but
    /// it must not replace the app's local thread id or the foreground window jumps
    /// to a state bucket with no messages.
    func testSwitchedProviderNativeSessionIdDoesNotReplaceLocalThreadId() async throws {
        let project = makeProject("provider-switch")
        appState.projects = [project]

        let localThreadId = "claude-thread-\(UUID().uuidString)"
        let codexNativeId = "codex-native-\(UUID().uuidString)"
        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = localThreadId
        window.sessionAgentProvider = .codex
        window.sessionModel = "gpt-5"

        var state = SessionStreamState()
        state.agentProvider = .codex
        state.model = "gpt-5"
        state.providerSessionIds = [AgentProvider.claudeCode.rawValue: localThreadId]
        state.messages = [ChatMessage(role: .user, content: "previous Claude turn")]
        appState.sessionStates[localThreadId] = state

        await mockBackend.enqueueScript(
            [
                .systemInit(sessionId: codexNativeId, delay: 0.01),
                .assistantText("Codex reply", delay: 0.01),
                .result(sessionId: codexNativeId, delay: 0.01),
            ],
            forCwd: project.path
        )

        let maybeStreamId = await appState.sendPrompt("continue with Codex", in: window)
        let streamId = try XCTUnwrap(maybeStreamId)
        _ = await appState.awaitStreamCompletion(streamId: streamId, timeout: 5, acceptsPartial: false)

        XCTAssertEqual(window.currentSessionId, localThreadId)
        XCTAssertFalse(appState.stateForSession(localThreadId).isStreaming)
        XCTAssertNil(appState.sessionStates[codexNativeId])
        XCTAssertEqual(
            appState.stateForSession(localThreadId).providerSessionIds[AgentProvider.codex.rawValue],
            codexNativeId
        )
        XCTAssertTrue(
            appState.stateForSession(localThreadId).messages.contains { $0.role == .assistant },
            "Assistant reply should remain attached to the local thread"
        )
    }

    func testExistingCrossProjectThreadUsesStoredProviderNativeSessionId() async throws {
        let project = makeProject("existing-provider-thread")
        appState.projects = [project]

        let localThreadId = "local-thread-\(UUID().uuidString)"
        let codexNativeId = "codex-native-\(UUID().uuidString)"
        let summary = ChatSession.Summary(
            id: localThreadId,
            projectId: project.id,
            title: "Codex thread",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: false,
            agentProvider: .codex,
            model: "gpt-5.4",
            origin: .codexAppServer
        )
        appState.allSessionSummaries = [summary]
        appState.threadStore.upsert(summary)
        appState.threadStore.setProviderSessionId(
            localId: localThreadId,
            providerRaw: AgentProvider.codex.rawValue,
            nativeId: codexNativeId
        )

        await mockBackend.enqueueScript(
            [
                .systemInit(sessionId: codexNativeId, delay: 0.01),
                .assistantText("existing Codex reply", delay: 0.01),
                .result(sessionId: codexNativeId, delay: 0.01),
            ],
            forCwd: project.path
        )

        let result = try await appState.sendCrossProject(
            projectId: nil,
            threadId: localThreadId,
            prompt: "continue existing Codex thread",
            waitForResponse: true,
            timeoutSeconds: 5
        )

        let requests = await mockBackend.receivedRequests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.sessionId, codexNativeId)
        XCTAssertEqual(request.model, "gpt-5.4")
        XCTAssertEqual(appState.stateForSession(localThreadId).agentProvider, .codex)
        XCTAssertEqual(result.threadId, localThreadId)
        XCTAssertTrue(result.done)
    }

    // MARK: - Helpers

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/rxcode-test-\(name)-\(UUID().uuidString)", gitHubRepo: nil)
    }
}
