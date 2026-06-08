import Foundation
import RxCodeCore

/// Process-global state shared by every workspace.
///
/// `AppState` is per-workspace (one instance per open workspace window), but a
/// handful of services must be shared across all of them:
///
/// - `metaStore` / `cliStore` read & write **global** on-disk locations
///   (`~/.claude/projects`, `~/Library/Application Support/RxCode/session-meta`)
///   that are not workspace-scoped. Giving each workspace its own instance would
///   create incoherent in-memory caches over the same files.
/// - `claude` manages CLI subprocess lifecycle (PGIDs, stdin handles, descendant
///   trackers) keyed by stream id. A single shared instance keeps one registry of
///   running streams across all windows. Event routing stays correct because each
///   `AppState` owns its own `AsyncStream` iteration (pull model) — see
///   `AppState+CrossProject.processStream`.
/// - `workspaceRegistry` is the single source of truth for the workspace list and
///   the active-workspace selection, persisted to `workspaces.json`.
///
/// One `AppCore` is created by `RxCodeApp` and handed to every `AppState`.
@Observable
@MainActor
final class AppCore {
    let metaStore: SessionMetaStore
    let cliStore: CLISessionStore
    let claude: ClaudeService
    let workspaceRegistry: WorkspaceRegistry

    init() {
        let metaStore = SessionMetaStore()
        let cliStore = CLISessionStore(metaStore: metaStore)
        self.metaStore = metaStore
        self.cliStore = cliStore
        self.claude = ClaudeService(cliStore: cliStore)
        self.workspaceRegistry = WorkspaceRegistry()
    }
}
