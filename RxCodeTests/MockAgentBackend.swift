import Foundation
import RxCodeCore

/// Test-only `AgentBackend` implementation that emits a scripted sequence of
/// `StreamEvent`s for each `send(_:)` call instead of spawning a real CLI.
///
/// Scripts are keyed by the request's `cwd` because the `streamId` is generated
/// inside `sendPrompt` and isn't visible to the test ahead of time. Each
/// enqueued script is consumed once (FIFO per cwd); if no script is registered
/// for a cwd, the mock emits a minimal init+result pair so `processStream`
/// completes cleanly without hanging the test.
actor MockAgentBackend: AgentBackend {

    // MARK: - Step

    struct Step: Sendable {
        /// Pause before yielding `event`. Use a long delay to simulate a
        /// stream that's "stuck mid-turn" (the cross-project freeze case).
        let delay: TimeInterval
        let event: StreamEvent

        static func systemInit(sessionId: String, delay: TimeInterval = 0.01) -> Step {
            Step(delay: delay, event: .system(SystemEvent(
                subtype: "init",
                sessionId: sessionId,
                tools: nil,
                model: nil,
                claudeCodeVersion: nil
            )))
        }

        static func assistantText(_ text: String, delay: TimeInterval = 0.01) -> Step {
            Step(delay: delay, event: .assistant(AssistantMessage(
                id: UUID().uuidString,
                role: "assistant",
                content: [.text(text)],
                usage: nil
            )))
        }

        static func result(sessionId: String, isError: Bool = false, delay: TimeInterval = 0.01) -> Step {
            Step(delay: delay, event: .result(ResultEvent(
                durationMs: 10,
                totalCostUsd: 0,
                sessionId: sessionId,
                isError: isError,
                totalTurns: 1,
                usage: nil,
                contextWindow: nil
            )))
        }
    }

    // MARK: - State

    nonisolated let provider: AgentProvider
    nonisolated let staticCapabilities: CapabilitySet

    /// FIFO per-cwd script queue. Each entry is one turn's events.
    private var scriptsByCwd: [String: [[Step]]] = [:]

    /// Observed `send(_:)` requests, in order. Tests can inspect to assert
    /// the orchestration layer dispatched what they expected.
    private(set) var receivedRequests: [BackendSendRequest] = []

    // MARK: - Init

    init(provider: AgentProvider = .claudeCode) {
        self.provider = provider
        self.staticCapabilities = provider.staticCapabilities
    }

    // MARK: - Test configuration

    /// Register one turn's worth of events for the next `send(_:)` whose
    /// `cwd` matches. Multiple enqueues for the same cwd are consumed FIFO.
    func enqueueScript(_ steps: [Step], forCwd cwd: String) {
        scriptsByCwd[cwd, default: []].append(steps)
    }

    // MARK: - AgentBackend

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        receivedRequests.append(request)

        let script: [Step]
        if var queue = scriptsByCwd[request.cwd], !queue.isEmpty {
            script = queue.removeFirst()
            scriptsByCwd[request.cwd] = queue
        } else {
            // No script registered — emit a harmless init+result so the
            // caller's `for await event in stream` terminates instead of
            // wedging the test.
            let sid = request.sessionId ?? UUID().uuidString
            script = [
                .systemInit(sessionId: sid),
                .result(sessionId: sid),
            ]
        }

        return AsyncStream<StreamEvent> { continuation in
            // Spawn outside the actor: the script's `Task.sleep` calls must
            // not hold the mock's actor lock or the test's own assertions
            // (which may also access the mock) would deadlock.
            Task.detached {
                for step in script {
                    if step.delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                    }
                    continuation.yield(step.event)
                }
                continuation.finish()
            }
        }
    }

    func cancel(streamId: UUID) {
        // No-op — scripts run to completion or hit `continuation.finish()` on
        // their own. Cancellation in the production backend kills the CLI
        // process; the mock has nothing analogous to tear down.
    }

    func finalize(streamId: UUID) {
        // No-op for the same reason as `cancel(streamId:)`.
    }
}
