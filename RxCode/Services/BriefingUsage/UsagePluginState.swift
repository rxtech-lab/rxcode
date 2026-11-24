import Foundation
import Observation
import RxCodeCore

@MainActor @Observable
final class UsagePluginState {
    let registry = UsagePluginRegistry()
    var dashboard = UsageDashboard()
    var error: String?
    var refreshing = false
    /// Integrations whose cards show placeholder rails until their fetch finishes.
    var refreshingIntegrationIDs: Set<UUID> = []
    var extensionStatuses: [UUID: UsageExtensionStatus] = [:]
    struct Refresh {
        let id: UUID
        let integration: UsageIntegration
        let workspace: URL
        let task: Task<Void, Never>
    }
    @ObservationIgnored var running: [UUID: Refresh] = [:]
    @ObservationIgnored var localRefreshPending = false
    @ObservationIgnored var localRefreshTask: Task<Void, Never>?
    var refreshPending = false
    @ObservationIgnored var refreshTask: Task<Void, Never>?
}
