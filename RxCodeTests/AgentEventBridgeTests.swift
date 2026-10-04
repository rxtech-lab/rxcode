import RxAgentCore
import RxCodeCore
import XCTest
@testable import RxCode

/// Covers the translation from RxAgentSDK's `AgentEvent` stream to the
/// `StreamEvent` stream `AppState` consumes.
///
/// The bridge is a value type fed from a literal array of events, so every case
/// here runs with no process, no socket and no UI — which is the point of doing
/// the decoding in the SDK rather than in app state.
final class AgentEventBridgeTests: XCTestCase {

    private func translate(_ events: [AgentEvent], acpClientID: String? = nil) -> [StreamEvent] {
        let bridge = AgentEventBridge(acpClientID: acpClientID)
        return events.flatMap { bridge.translate($0) }
    }

    // MARK: - Session

    func testSessionStartedBecomesInitSystemEvent() {
        let events = translate([
            .sessionStarted(SessionStarted(
                nativeSessionID: "sess-1",
                model: "claude-opus-5",
                advertisedTools: ["Read", "Bash"]
            )),
        ])

        guard case .system(let system)? = events.first else {
            return XCTFail("Expected a system event, got \(events)")
        }
        XCTAssertEqual(system.subtype, "init")
        XCTAssertEqual(system.sessionId, "sess-1")
        XCTAssertEqual(system.model, "claude-opus-5")
        XCTAssertEqual(system.tools, ["Read", "Bash"])
    }

    /// The turn's result has to carry the session id even though the SDK
    /// reported it several events earlier, because that is the only place
    /// `AppState` reads it from when persisting the resume point.
    func testResultCarriesTheSessionIdReportedAtStart() {
        let events = translate([
            .sessionStarted(SessionStarted(nativeSessionID: "sess-2")),
            .turnEnded(TurnResult()),
        ])

        guard case .result(let result)? = events.last else {
            return XCTFail("Expected a result event, got \(events)")
        }
        XCTAssertEqual(result.sessionId, "sess-2")
        XCTAssertFalse(result.isError)
    }

    // MARK: - Blocks

    func testDeltasAndToolCallsMapOneToOne() {
        let events = translate([
            .textDelta("Hel"),
            .textDelta("lo"),
            .toolCallStarted(id: "t1", name: "Read"),
            .toolCallInput(id: "t1", input: ["file_path": .string("/tmp/a.swift")]),
            .toolCallResult(id: "t1", content: "contents", isError: false),
        ])

        XCTAssertEqual(events.count, 5)
        guard case .textDelta(let first) = events[0], case .textDelta(let second) = events[1] else {
            return XCTFail("Expected two text deltas, got \(events)")
        }
        XCTAssertEqual(first + second, "Hello")

        guard case .toolCallStarted(let id, let name) = events[2] else {
            return XCTFail("Expected a tool call start, got \(events[2])")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(name, "Read")

        guard case .toolCallInput(_, let input) = events[3] else {
            return XCTFail("Expected tool call input, got \(events[3])")
        }
        XCTAssertEqual(input["file_path"], .string("/tmp/a.swift"))

        guard case .user(let user) = events[4] else {
            return XCTFail("Expected a tool result, got \(events[4])")
        }
        XCTAssertEqual(user.toolUseId, "t1")
        XCTAssertEqual(user.content, "contents")
        XCTAssertFalse(user.isError)
    }

    /// Structural events exist so the SDK's own reducer can be a pure function.
    /// RxCode infers the same structure from the deltas, so forwarding them
    /// would be noise in an already busy stream.
    func testStructuralEventsAreDropped() {
        let events = translate([
            .turnStarted(turnID: UUID()),
            .messageStarted(role: .assistant, id: "m1"),
            .blockStarted(.text),
            .blockEnded(.text),
            .diagnostic(AgentDiagnostic(level: .debug, client: .claudeCode, message: "hi")),
        ])
        XCTAssertTrue(events.isEmpty, "Expected no output, got \(events)")
    }

    /// Approvals are answered through the injected resolver, which already
    /// drives the permission sheet. Forwarding the event too would raise the
    /// sheet a second time for one tool call.
    func testPermissionRequestIsNotForwarded() {
        let events = translate([
            .permissionRequested(RxAgentCore.PermissionRequest(
                id: "t1", toolName: "Bash", toolInput: [:], mode: .default
            )),
        ])
        XCTAssertTrue(events.isEmpty, "Expected no output, got \(events)")
    }

    // MARK: - Side channels

    func testContextWindowIsHeldUntilTheResult() {
        let events = translate([
            .contextWindow(RxAgentCore.ContextWindowInfo(usedTokens: 40_000, maxTokens: 200_000)),
            .turnEnded(TurnResult()),
        ])

        XCTAssertEqual(events.count, 1, "The context window is not its own StreamEvent")
        guard case .result(let result)? = events.first else {
            return XCTFail("Expected a result event, got \(events)")
        }
        XCTAssertEqual(result.contextWindow?.usedPercentage ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(result.contextWindow?.remainingPercentage ?? 0, 80, accuracy: 0.001)
    }

    func testUsageAndCostReachTheResult() {
        let usage = RxAgentCore.UsageInfo(
            inputTokens: 100, outputTokens: 20,
            cacheReadTokens: 5, cacheCreationTokens: 7, totalCostUSD: 0.25
        )
        let events = translate([.turnEnded(TurnResult(usage: usage))])

        guard case .result(let result)? = events.first else {
            return XCTFail("Expected a result event, got \(events)")
        }
        XCTAssertEqual(result.usage?.inputTokens, 100)
        XCTAssertEqual(result.usage?.outputTokens, 20)
        XCTAssertEqual(result.usage?.cacheReadInputTokens, 5)
        XCTAssertEqual(result.usage?.cacheCreationInputTokens, 7)
        XCTAssertEqual(result.totalCostUsd, 0.25)
    }

    func testTodosBecomeASnapshotForTheLiveSession() {
        let events = translate([
            .sessionStarted(SessionStarted(nativeSessionID: "sess-3")),
            .todos([
                RxAgentCore.TodoItem(id: 0, content: "Write it", activeForm: "Writing it", status: .inProgress),
            ]),
        ])

        guard case .todoSnapshot(let snapshot)? = events.last else {
            return XCTFail("Expected a todo snapshot, got \(events)")
        }
        XCTAssertEqual(snapshot.sessionId, "sess-3")
        XCTAssertEqual(snapshot.items.map(\.status), [.inProgress])
        XCTAssertEqual(snapshot.items.map(\.activeForm), ["Writing it"])
    }

    /// Model lists only mean something for ACP, where they are written back to
    /// the `ACPClientSpec` they came from. A Claude or Codex bridge has no spec
    /// to attribute them to.
    func testDiscoveredModelsOnlySurfaceForACP() {
        let discovered = AgentEvent.modelsDiscovered([
            AgentModelOption(id: "pro", displayName: "Pro"),
        ])

        XCTAssertTrue(translate([discovered]).isEmpty)

        let acp = translate([discovered], acpClientID: "gemini")
        guard case .acpModelsDiscovered(let event)? = acp.first else {
            return XCTFail("Expected discovered models, got \(acp)")
        }
        XCTAssertEqual(event.clientId, "gemini")
        XCTAssertEqual(event.config.options.map(\.value), ["pro"])
    }

    func testRateLimitResetInThePastReportsNoCountdown() {
        let events = translate([
            .rateLimit(RxAgentCore.RateLimitInfo(
                message: "Slow down", resetsAt: Date().addingTimeInterval(-60)
            )),
        ])

        guard case .rateLimitEvent(let info)? = events.first else {
            return XCTFail("Expected a rate limit event, got \(events)")
        }
        XCTAssertEqual(info.status, "Slow down")
        XCTAssertEqual(info.retrySec ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Background tasks

    /// A turn that spawns a background task ends with a result while the task is
    /// still running. `AppState` keeps the turn in progress until a result
    /// tagged `task-notification` arrives, so the tag has to survive the bridge.
    func testBackgroundFollowUpResultKeepsItsOriginKind() {
        let events = translate([
            .backgroundTask(BackgroundTaskEvent(taskID: "bg1", status: .started)),
            .turnEnded(TurnResult(isBackgroundFollowUp: true)),
        ])

        guard case .system(let system)? = events.first else {
            return XCTFail("Expected a system event, got \(events)")
        }
        XCTAssertEqual(system.subtype, "task_started")
        XCTAssertEqual(system.taskId, "bg1")
        XCTAssertNil(system.taskStatus, "task_started has no status; it means running")

        guard case .result(let result)? = events.last else {
            return XCTFail("Expected a result event, got \(events)")
        }
        XCTAssertTrue(result.isTaskNotification)
    }

    // MARK: - Failure

    func testFailureEndsTheTurnAsAnError() {
        let events = translate([.failed(.binaryNotFound(name: "claude"))])

        guard case .result(let result)? = events.first else {
            return XCTFail("Expected a result event, got \(events)")
        }
        XCTAssertTrue(result.isError)
    }

    /// Cancelling is the user pressing stop. The turn still has to be closed
    /// out, but an error bubble for a deliberate interruption is noise.
    func testCancellationEndsTheTurnWithoutAnError() {
        let events = translate([.failed(.cancelled)])

        guard case .result(let result)? = events.first else {
            return XCTFail("Expected a result event, got \(events)")
        }
        XCTAssertFalse(result.isError)
        XCTAssertNil(AgentEventBridge.failureDetail(.failed(.cancelled)))
    }

    func testFailureDetailIsOfferedForTheErrorBubble() {
        let detail = AgentEventBridge.failureDetail(.failed(.binaryNotFound(name: "claude")))
        XCTAssertEqual(detail, "Could not find `claude` on PATH.")
    }

    // MARK: - Thread identity

    func testThreadIDIsStableAndReusesUUIDSessionKeys() {
        let uuid = UUID()
        XCTAssertEqual(
            SDKAgentBackend.threadID(forSessionKey: uuid.uuidString).rawValue,
            uuid,
            "A session key that is already a UUID should be used as-is"
        )

        // Stability is the whole requirement: the same key must map to the same
        // thread on a later launch, which rules out `Hasher`'s per-process seed.
        let first = SDKAgentBackend.threadID(forSessionKey: "new-session:project-1")
        let second = SDKAgentBackend.threadID(forSessionKey: "new-session:project-1")
        let other = SDKAgentBackend.threadID(forSessionKey: "new-session:project-2")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
    }
}
