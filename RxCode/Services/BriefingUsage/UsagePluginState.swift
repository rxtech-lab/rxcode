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
    var refreshPending = false
    @ObservationIgnored var refreshTask: Task<Void, Never>?
}
