import Foundation
import os
import RxCodeCore

/// Coordinates the debounced start of an automatic code review and its
/// cancellation. Owned by `AppState`, driven by `CodeReviewHook` through the
/// `HookController`.
///
/// The flow, keyed by the reviewed thread's `parentSessionKey`:
///   1. The hook inserts a countdown card and calls `awaitGate(...)`, which
///      suspends for `delaySeconds` (default 60).
///   2. During that window the user can:
///        - tap **Start it now**  → `startNow` → the gate resolves `.proceed`,
///        - tap **Stop Review** or send a new message in the thread → `cancel`
///          → the gate resolves `.cancelled`.
///   3. If nothing happens, the timer fires and the gate resolves `.proceed`.
///
/// After the gate proceeds the hook runs the review thread; the hook brackets
/// that work with `markRunning` / `clearRunning` so a later `cancel` (a new
/// follow-up message, or the "Stop Code Review" context-menu item) stops the
/// in-flight review thread too.
@MainActor
final class ReviewScheduler {
    /// How a pending countdown resolved.
    enum GateOutcome {
        case proceed
        case cancelled
    }

    /// Default debounce before an automatic review starts.
    static let defaultDelaySeconds: TimeInterval = 60

    private weak var app: AppState?
    private let logger = Logger(subsystem: "com.claudework", category: "ReviewScheduler")

    private struct Gate {
        var continuation: CheckedContinuation<GateOutcome, Never>?
        var timer: Task<Void, Never>?
    }

    /// Pending countdowns awaiting resolution, keyed by parent session key.
    private var gates: [String: Gate] = [:]
    /// Parent keys whose review thread is currently running (post-gate).
    private var running: Set<String> = []
    /// Resolved review-thread session id, keyed by parent. Populated by
    /// `registerRunningReviewThread` as soon as `sendCrossProject` stamps the
    /// child's linkage — well before the review's response is awaited — so a
    /// cancel can interrupt the exact thread instead of guessing from summaries.
    private var reviewThreadByParent: [String: String] = [:]
    /// Parent keys cancelled while running *before* their review-thread id was
    /// known. The stop is applied the instant `registerRunningReviewThread` runs.
    private var pendingStop: Set<String> = []
    /// Parent keys we actually stopped while running, so the hook can render a
    /// "stopped" card instead of an "ended without verdict" one when its awaited
    /// review thread returns empty because we interrupted it.
    private var stoppedWhileRunning: Set<String> = []
    /// Why the most recent cancel happened, keyed by parent — drives card copy.
    private var cancelReasonByParent: [String: ReviewCancelReason] = [:]

    init(app: AppState) {
        self.app = app
    }

    /// Suspend until the countdown elapses, the user starts it now, or it is
    /// cancelled. Replaces any pre-existing gate for the same key.
    func awaitGate(parentSessionKey key: String, delaySeconds: TimeInterval) async -> GateOutcome {
        // Fresh review for this thread — clear any state left from a prior one.
        stoppedWhileRunning.remove(key)
        pendingStop.remove(key)
        reviewThreadByParent[key] = nil
        cancelReasonByParent[key] = nil
        // Defensive: resolve a stale gate for this key before starting a new one.
        resolve(key, .cancelled)

        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delaySeconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolve(key, .proceed)
        }
        return await withCheckedContinuation { continuation in
            gates[key] = Gate(continuation: continuation, timer: timer)
        }
    }

    /// Skip the remaining delay and begin the review now.
    func startNow(parentSessionKey key: String) {
        logger.debug("[Review] start-now for \(key, privacy: .public)")
        resolve(key, .proceed)
    }

    /// Cancel a pending countdown and/or stop an in-flight review thread.
    func cancel(parentSessionKey key: String, reason: ReviewCancelReason) {
        let hadGate = gates[key] != nil
        let isRunning = running.contains(key)
        guard hadGate || isRunning else { return }

        cancelReasonByParent[key] = reason
        if hadGate {
            resolve(key, .cancelled)
        }
        if isRunning {
            if let reviewId = reviewThreadByParent[key] {
                // Only count it as "stopped" if there was actually a live stream
                // to interrupt. If the review child already finished, let its
                // real PASS/FAIL verdict stand instead of discarding it.
                if app?.interruptReviewThread(sessionId: reviewId) == true {
                    stoppedWhileRunning.insert(key)
                }
            } else {
                // Review is starting but its thread id isn't known yet; stop it
                // the moment `registerRunningReviewThread` registers the id.
                pendingStop.insert(key)
            }
        }
        logger.debug("[Review] cancel \(key, privacy: .public) reason=\(reason.rawValue, privacy: .public) gate=\(hadGate, privacy: .public) running=\(isRunning, privacy: .public)")
    }

    /// Register the spawned review thread's session id so a cancel can target it
    /// directly. Applies a stop immediately if one was requested before now.
    func registerRunningReviewThread(parentSessionKey key: String, reviewThreadId: String) {
        reviewThreadByParent[key] = reviewThreadId
        if pendingStop.remove(key) != nil {
            // Apply the stop requested before the id was known. Only mark stopped
            // if a live stream was actually interrupted.
            if app?.interruptReviewThread(sessionId: reviewThreadId) == true {
                stoppedWhileRunning.insert(key)
            }
        }
    }

    /// Whether a review is pending (counting down) or actively running for the
    /// thread — drives the "Stop Code Review" context-menu item's visibility.
    func hasOngoingReview(parentSessionKey key: String) -> Bool {
        gates[key] != nil || running.contains(key)
    }

    /// Mark the review thread as running (post-gate, while the hook awaits it).
    func markRunning(parentSessionKey key: String) {
        running.insert(key)
    }

    /// Clear the running flag once the hook's review thread returns.
    func clearRunning(parentSessionKey key: String) {
        running.remove(key)
        reviewThreadByParent[key] = nil
        pendingStop.remove(key)
    }

    /// One-shot: did we stop this review while it was running? Clears the flag.
    func consumeStoppedWhileRunning(parentSessionKey key: String) -> Bool {
        stoppedWhileRunning.remove(key) != nil
    }

    /// The reason the most recent cancel happened for this thread (non-consuming).
    func cancelReason(parentSessionKey key: String) -> ReviewCancelReason? {
        cancelReasonByParent[key]
    }

    // MARK: - Private

    private func resolve(_ key: String, _ outcome: GateOutcome) {
        guard var gate = gates[key], let continuation = gate.continuation else { return }
        gate.continuation = nil
        gate.timer?.cancel()
        gates[key] = nil
        continuation.resume(returning: outcome)
    }
}

extension AppState {
    /// Interrupt a specific (review) thread's in-flight stream. Returns `true`
    /// only when there was actually a live stream to cancel — so callers don't
    /// report a review as "stopped" when the child had already finished.
    @discardableResult
    func interruptReviewThread(sessionId: String) -> Bool {
        guard sessionStates[sessionId]?.isStreaming == true else { return false }
        let projectId = allSessionSummaries.first(where: { $0.id == sessionId })?.projectId
        let project = projectId.flatMap { id in projects.first { $0.id == id } }
        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionId
        // Review threads skip lifecycle hooks, so there are no stop hooks to fire.
        Task { [weak self] in
            await self?.cancelStreaming(in: window, fireStopHooks: false)
        }
        return true
    }
}
