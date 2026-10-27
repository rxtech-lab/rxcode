import Foundation
import Observation
import RxCodeCore

@MainActor @Observable
final class UsagePluginState {
    let registry = UsagePluginRegistry()
    var dashboard = UsageDashboard()
    var error: String?
    var refreshing = false
    var refreshPending = false
    @ObservationIgnored var refreshTask: Task<Void, Never>?
}
