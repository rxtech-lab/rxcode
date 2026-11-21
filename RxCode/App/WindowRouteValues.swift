import Foundation
import RxCodeCore

// MARK: - WorkspaceWindowValue

/// Identifies which workspace a main window is bound to. The primary
/// `WindowGroup` is keyed by this value so each workspace gets its own window
/// (and its own `AppState`), and reopening the same workspace refocuses its
/// existing window rather than spawning a duplicate.
struct WorkspaceWindowValue: Codable, Hashable {
    let workspaceID: String
}

// MARK: - ProjectWindowValue

struct ProjectWindowValue: Codable, Hashable {
    let projectId: UUID
    let instanceId: UUID
    /// Workspace that owns this project, so a detached project window resolves
    /// the correct per-workspace `AppState`.
    var workspaceID: String?
}

// MARK: - ChatWindowValue

/// Identifies a detached Chat-tab window. `instanceId` lets the user open
/// several independent chat windows for the same workspace.
struct ChatWindowValue: Codable, Hashable {
    let instanceId: UUID
    var workspaceID: String?
    var sessionId: String? = nil
    var localModelID: String? = nil
}

// MARK: - GeneralRouteWindowValue

/// Identifies a detached General-route window (Projects, Briefing, Scheduled)
/// opened from the sidebar row's context menu. `instanceId` lets the user open
/// several independent windows for the same route.
struct GeneralRouteWindowValue: Codable, Hashable {
    let route: GeneralRoute
    let instanceId: UUID
    var workspaceID: String?
    var taskDetailProjectId: UUID?
}

// MARK: - TerminalWindowValue

struct TerminalWindowValue: Codable, Hashable {
    let path: String
}
