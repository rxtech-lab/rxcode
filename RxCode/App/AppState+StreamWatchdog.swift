import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Stream Inactivity Watchdog

    /// Wall-clock seconds of stream silence after which the watchdog decides
    /// the agent is wedged and force-cleans the session. Sized to cover long
    /// legitimate gaps — model thinking, a slow `Bash` tool, an LLM-side
    /// rate-limit retry — without being so generous that a truly stuck thread
    /// stays stuck for the rest of the user's session.
    static let streamInactivityTimeout: TimeInterval = 600

    /// How often the watchdog wakes up to recompute the gap. Short enough that
    /// the unstick fires within a few seconds of the threshold without burning
    /// CPU when the stream is healthy.
    static let streamInactivityPollInterval: UInt64 = 15 * 1_000_000_000

    /// Spawn a background poller that unblocks the session when the agent goes
    /// silent without finishing. Without this, a dead/wedged CLI would leave
    /// `isStreaming`/`activeStreamId` set forever — every subsequent send into
    /// the same thread would no-op silently, which is why users had to start a
    /// brand new thread to "fix" a stuck one.
    ///
    /// Self-cancels when the session is no longer streaming, when ownership
    /// has moved to another stream, or when no events have been recorded yet.
    /// Otherwise on threshold-cross it cancels the backend (so the CLI process
    /// gets SIGINT/SIGKILL), cancels the stream task (so `processStream`'s
    /// `for await` unblocks), force-finalizes session state, and surfaces an
    /// error bubble in the foreground window if the user is looking at it.
    @MainActor
    func startStreamWatchdog(
        streamId: UUID,
        sessionKey initialKey: String,
        agentProvider: AgentProvider,
        projectID: UUID,
        in window: WindowState
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamInactivityPollInterval)
                guard !Task.isCancelled else { return }
                guard let self else { return }

                // Resolve the live session key — the CLI may have rotated
                // session_id mid-stream (compact_boundary, pending → real
                // promotion), so the key the watchdog was spawned with may
                // have been renamed under it.
                let currentKey = self.resolveCurrentSessionId(initialKey)
                let state = self.stateForSession(currentKey)

                guard state.isStreaming, state.activeStreamId == streamId else { return }

                // A live "backend agent" background task can legitimately run
                // silent for far longer than the inactivity timeout while the
                // turn waits to run its autonomous follow-up. Don't force-clean
                // (which would SIGKILL the CLI and the task) while one is pending.
                guard state.liveBackgroundTaskIds.isEmpty else { continue }

                guard let last = state.lastStreamEventDate else { continue }

                let gap = Date().timeIntervalSince(last)
                guard gap >= Self.streamInactivityTimeout else { continue }

                self.logger.error("[Stream:Watchdog] no events for \(Int(gap))s on session=\(currentKey, privacy: .public) stream=\(streamId) — force-cleaning")

                self.sessionStates[currentKey]?.streamTask?.cancel()
                let message = "Agent stopped responding after \(Int(gap))s of silence."
                await self.interruptStream(sessionID: currentKey, streamID: streamId, projectID: projectID, message: message)
                await self.backend(for: agentProvider).cancel(streamId: streamId)
                if window.currentSessionId == currentKey {
                    window.errorMessage = message
                    window.showError = true
                }
                return
            }
        }
    }
}
