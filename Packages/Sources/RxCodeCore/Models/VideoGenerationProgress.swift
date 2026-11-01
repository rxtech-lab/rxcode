import Foundation

/// Live status of a local studio tool call (`VideoGeneration`,
/// `ImageGeneration`, `AudioGeneration`, `Decision`), posted on the default
/// `NotificationCenter` while the tool runs. The agent SDK does not forward
/// tool progress events, so the studios listen for these instead.
///
/// Every post is both the take's current headline and one line of its
/// activity log. `actor` names who did the step when it was not RxCode itself,
/// e.g. the task model looking up the companion files.
public enum VideoGenerationProgress {
    public static let toolName = "VideoGeneration"
    public static let notification = Notification.Name("RxCodeVideoGenerationProgress")
    public static let callIDKey = "callID"
    public static let statusKey = "status"
    public static let actorKey = "actor"

    public static func post(callID: String, status: String, actor: String? = nil) {
        var info: [String: String] = [callIDKey: callID, statusKey: status]
        info[actorKey] = actor
        NotificationCenter.default.post(name: notification, object: nil, userInfo: info)
    }
}

/// One line of a video generation's activity log.
public struct VideoGenerationActivity: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let date: Date
    public let message: String
    /// The task model's label for steps it took; nil for RxCode's own steps.
    public let actor: String?

    public init(date: Date = Date(), message: String, actor: String?) {
        self.date = date
        self.message = message
        self.actor = actor
    }
}
