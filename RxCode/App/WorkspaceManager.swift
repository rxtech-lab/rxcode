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
}
