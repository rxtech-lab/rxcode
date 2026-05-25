import Foundation

/// Lightweight, transport-agnostic analytics dispatch shared by macOS, iOS, and
/// any future hosts. App targets install a handler at launch (typically wired
/// to Firebase Analytics) and view code calls `AnalyticsService.shared.log(_:)`
/// without taking a Firebase dependency on `RxCodeCore`.
public final class AnalyticsService: @unchecked Sendable {
    public static let shared = AnalyticsService()

    public typealias Handler = (_ name: String, _ parameters: [String: Any]?) -> Void

    private let queue = DispatchQueue(label: "com.rxlab.rxcode.analytics")
    private var handler: Handler?

    private init() {}

    public func install(handler: @escaping Handler) {
        queue.sync { self.handler = handler }
    }

    public func log(_ event: AnalyticsEvent, parameters: [String: Any]? = nil) {
        log(name: event.rawValue, parameters: parameters)
    }

    public func log(name: String, parameters: [String: Any]? = nil) {
        let handler = queue.sync { self.handler }
        handler?(name, parameters)
    }
}

/// Canonical names for the custom events emitted by the apps. Keeping them in
/// one enum avoids drift between platforms and keeps Firebase dashboards tidy.
public enum AnalyticsEvent: String, Sendable {
    // Navigation
    case briefingListOpened = "briefing_list_opened"
    case briefingDetailOpened = "briefing_detail_opened"
    case threadOpened = "thread_opened"
    case threadCreated = "thread_created"
    case projectOpened = "project_opened"

    // Feature surfaces
    case diffViewOpened = "diff_view_opened"
    case runProfileEditorOpened = "run_profile_editor_opened"
    case runProfileExecuted = "run_profile_executed"
    case inAppBrowserOpened = "in_app_browser_opened"

    // Misc
    case settingsOpened = "settings_opened"
    case newProjectStarted = "new_project_started"
}
