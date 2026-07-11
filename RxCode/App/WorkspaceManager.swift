import Foundation
import RxCodeCore

/// Owns the process-global `AppCore` and vends one `AppState` per workspace.
///
/// Each open workspace window binds to the `AppState` returned by
/// `appState(for:)`; instances are cached for the app's lifetime so reopening a
/// workspace window reuses its state (and any in-flight chats keep running).
///
/// Global surfaces that aren't tied to a single window — the menu bar, Settings,
/// mobile sync — follow `frontmostAppState`, i.e. whichever workspace window is
/// currently key.
@Observable
@MainActor
final class WorkspaceManager {
    let core: AppCore

    /// One AppState per workspace id, created lazily on first access.
    private var appStatesByWorkspaceID: [String: AppState] = [:]

    /// Workspace id of the key/frontmost window. Global surfaces follow this.
    var frontmostWorkspaceID: String

    /// Workspace that currently owns mobile sync (the inbound mobile-request
    /// observers + resolvers). Follows the frontmost window.
    private var mobileSyncOwnerID: String?
    /// Whether `MobileSyncService.start()` has run (it is process-global and not
    /// idempotent, so it must fire exactly once).
    private var didStartMobileSync = false
    @ObservationIgnored private var performanceMonitorTask: Task<Void, Never>?

    init() {
        let core = AppCore()
        self.core = core
        self.frontmostWorkspaceID = core.workspaceRegistry.load().active.id
    }

    /// Known workspaces — source of truth is the shared registry.
    var workspaces: [AppWorkspace] { core.workspaceRegistry.load().all }

    /// Returns the AppState bound to `workspaceID`, creating it on first use.
    /// Falls back to the registry's active workspace when the id is unknown.
    func appState(for workspaceID: String) -> AppState {
        if let existing = appStatesByWorkspaceID[workspaceID] {
            return existing
        }
        let snapshot = core.workspaceRegistry.load()
        let workspace = snapshot.all.first { $0.id == workspaceID } ?? snapshot.active
        let appState = AppState(core: core, workspace: workspace)
        appStatesByWorkspaceID[workspace.id] = appState
        startPerformanceMonitorIfNeeded()
        return appState
    }

    /// AppState for the frontmost workspace window — used by global surfaces.
    var frontmostAppState: AppState { appState(for: frontmostWorkspaceID) }

    /// Whether an AppState has already been created for this workspace.
    func hasAppState(for workspaceID: String) -> Bool {
        appStatesByWorkspaceID[workspaceID] != nil
    }

    /// Mark a workspace window as frontmost (called from window focus tracking).
    /// Moves mobile-sync ownership to the new frontmost workspace.
    func markFrontmost(_ workspaceID: String) {
        frontmostWorkspaceID = workspaceID
        transferMobileSyncOwnership(to: workspaceID)
    }

    /// Hand mobile-sync ownership to `workspaceID`, tearing it down on the
    /// previous owner. Starts the (non-idempotent) mobile service once.
    private func transferMobileSyncOwnership(to workspaceID: String) {
        guard mobileSyncOwnerID != workspaceID else { return }
        if let previous = mobileSyncOwnerID, let previousState = appStatesByWorkspaceID[previous] {
            previousState.unbindMobileSyncOwnership()
        }
        appState(for: workspaceID).bindMobileSyncOwnership()
        mobileSyncOwnerID = workspaceID

        if !didStartMobileSync {
            MobileSyncService.shared.start()
            didStartMobileSync = true
        }
    }

    /// Drop a cached AppState (e.g. when its workspace is deleted). If the
    /// deleted workspace was frontmost, fall back to Personal so global surfaces
    /// resolve to a valid workspace.
    func discard(_ workspaceID: String) {
        appStatesByWorkspaceID[workspaceID]?.unbindMobileSyncOwnership()
        appStatesByWorkspaceID[workspaceID] = nil
        if mobileSyncOwnerID == workspaceID {
            mobileSyncOwnerID = nil
        }
        if frontmostWorkspaceID == workspaceID {
            markFrontmost(AppWorkspace.personalID)
        }
    }

    private func startPerformanceMonitorIfNeeded() {
        guard performanceMonitorTask == nil else { return }
        performanceMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await PerformanceDiagnosticsService.shared.append(
                state: await performanceStateSnapshot(),
                mainActorMaxLagMilliseconds: 0
            )

            let clock = ContinuousClock()
            var lastSample = clock.now
            var maximumLagMilliseconds = 0.0

            while !Task.isCancelled {
                let expectedWake = clock.now.advanced(by: .seconds(5))
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }

                let now = clock.now
                let lag = expectedWake.duration(to: now).components
                let lagMilliseconds = max(
                    0,
                    Double(lag.seconds) * 1_000
                        + Double(lag.attoseconds) / 1_000_000_000_000_000
                )
                maximumLagMilliseconds = max(maximumLagMilliseconds, lagMilliseconds)

                guard lastSample.duration(to: now) >= .seconds(30) else { continue }
                let snapshot = await performanceStateSnapshot()
                let intervalMaximumLag = maximumLagMilliseconds
                lastSample = now
                maximumLagMilliseconds = 0
                await PerformanceDiagnosticsService.shared.append(
                    state: snapshot,
                    mainActorMaxLagMilliseconds: intervalMaximumLag
                )
            }
        }
    }

    private func performanceStateSnapshot() async -> PerformanceStateSnapshot {
        let appStates = Array(appStatesByWorkspaceID.values)
        let states = appStates.flatMap { $0.sessionStates.values }
        let messageCounts = states.map { $0.messages.count }
        var searchIndexedThreadCount = 0
        var searchChunkCount = 0
        for appState in appStates {
            let stats = await appState.searchService.diagnosticStats()
            searchIndexedThreadCount += stats.threadCount
            searchChunkCount += stats.chunkCount
        }
        return PerformanceStateSnapshot(
            workspaceCount: appStatesByWorkspaceID.count,
            projectCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.projects.count },
            sessionSummaryCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.allSessionSummaries.count },
            inMemorySessionCount: states.count,
            inMemoryMessageCount: messageCounts.reduce(0, +),
            inMemoryBlockCount: states.reduce(0) { total, state in
                total + state.messages.reduce(0) { $0 + $1.blocks.count }
            },
            largestSessionMessageCount: messageCounts.max() ?? 0,
            activeStreamCount: states.count { $0.isStreaming },
            streamTaskCount: states.count { $0.streamTask != nil },
            flushTaskCount: states.count { $0.flushTask != nil },
            editingFileSnapshotCount: states.reduce(0) { $0 + $1.editingFileSnapshots.count },
            sessionRedirectCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.sessionIdRedirect.count },
            pendingCompletionCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.pendingStreamCompletions.count },
            completionWaiterCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.streamCompletionWaiters.count },
            pendingMobileRequestCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.mobilePendingRequests.count },
            reconciledSessionCount: appStatesByWorkspaceID.values.reduce(0) { $0 + $1.lastReconciledJsonlSize.count },
            searchIndexedThreadCount: searchIndexedThreadCount,
            searchChunkCount: searchChunkCount
        )
    }
}
