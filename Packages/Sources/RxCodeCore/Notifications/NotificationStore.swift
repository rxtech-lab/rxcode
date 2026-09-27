import Foundation
import os

/// Per-project choice for sending published briefings as Autopilot
/// notifications.
public enum BriefingNotificationMode: String, Codable, Sendable, CaseIterable {
    /// The general AI task agent reads the briefing and the project's setup
    /// and decides whether it is worth a notification.
    case automatic
    /// Every published briefing is sent (unless the run already sent one).
    case always
    /// Briefings of this project are never sent.
    case never
}

/// Local settings for sending briefings through the Autopilot notification
/// service.
public struct BriefingNotificationSettings: Codable, Sendable, Equatable {
    /// Master switch for briefing notifications.
    public var isEnabled: Bool
    /// Where notifications go. `nil` sends to the Autopilot account email;
    /// otherwise a verified trusted email.
    public var recipient: String?
    /// Mode for projects without their own choice, and for briefings that
    /// belong to no project.
    public var defaultMode: BriefingNotificationMode
    /// Per-project overrides keyed by project id.
    public var projectModes: [UUID: BriefingNotificationMode]

    public init(
        isEnabled: Bool = true,
        recipient: String? = nil,
        defaultMode: BriefingNotificationMode = .automatic,
        projectModes: [UUID: BriefingNotificationMode] = [:]
    ) {
        self.isEnabled = isEnabled
        self.recipient = recipient
        self.defaultMode = defaultMode
        self.projectModes = projectModes
    }

    /// The effective mode for a briefing of `projectId`.
    public func mode(for projectId: UUID?) -> BriefingNotificationMode {
        guard isEnabled else { return .never }
        return projectId.flatMap { projectModes[$0] } ?? defaultMode
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, recipient, defaultMode, projectModes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        recipient = try? c.decodeIfPresent(String.self, forKey: .recipient)
        defaultMode = (try? c.decodeIfPresent(BriefingNotificationMode.self, forKey: .defaultMode)) ?? .automatic
        // Keys are stored as UUID strings; unknown modes are dropped.
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .projectModes)) ?? [:]
        projectModes = raw.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key), let mode = BriefingNotificationMode(rawValue: entry.value) {
                result[id] = mode
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(recipient, forKey: .recipient)
        try c.encode(defaultMode, forKey: .defaultMode)
        try c.encode(
            Dictionary(uniqueKeysWithValues: projectModes.map { ($0.key.uuidString, $0.value.rawValue) }),
            forKey: .projectModes
        )
    }
}

/// A locally recorded notification: sent through Autopilot, failed, or a
/// briefing the app decided not to send.
public struct NotificationRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Sent automatically after a briefing was published.
        case briefing
        /// Sent by an agent through the `ide__send_notification` tool.
        case agent
        /// A scheduled task's completion report.
        case scheduledTask
        /// Sent by the user from a briefing.
        case user
    }

    public enum Status: String, Codable, Sendable {
        case sent
        case failed
        /// A published briefing that was deliberately not sent.
        case skipped
    }

    public let id: UUID
    public var source: Source
    public var status: Status
    /// Delivery channel on the Autopilot notification service (`email`).
    public var channel: String
    /// Server-side notification id, when one was created.
    public var remoteId: String?
    public var recipient: String?
    public var subject: String
    public var briefingId: UUID?
    public var projectId: UUID?
    /// The chat session whose agent produced the notification or briefing.
    public var sessionKey: String?
    /// Why the notification was skipped, or the agent's reason for sending.
    public var reason: String?
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        source: Source,
        status: Status,
        channel: String = "email",
        remoteId: String? = nil,
        recipient: String? = nil,
        subject: String,
        briefingId: UUID? = nil,
        projectId: UUID? = nil,
        sessionKey: String? = nil,
        reason: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.source = source
        self.status = status
        self.channel = channel
        self.remoteId = remoteId
        self.recipient = recipient
        self.subject = subject
        self.briefingId = briefingId
        self.projectId = projectId
        self.sessionKey = sessionKey
        self.reason = reason
        self.errorMessage = errorMessage
        // Whole seconds, the precision the ISO-8601 history file keeps.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }
}

/// File-backed store for briefing notification settings and the local history
/// of notifications sent through the Autopilot notification service:
///
/// ```
/// notifications/
///   settings.json   BriefingNotificationSettings
///   history.json    [NotificationRecord], newest first
/// ```
public actor NotificationStore {
    /// History entries kept on disk; older ones are dropped.
    public static let historyLimit = 500

    public nonisolated let baseURL: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.claudework", category: "NotificationStore")
    private var cachedHistory: [NotificationRecord]?

    public init(baseURL: URL = AppSupport.bundleScopedURL.appendingPathComponent("notifications", isDirectory: true)) {
        self.baseURL = baseURL
    }

    private var settingsURL: URL { baseURL.appendingPathComponent("settings.json") }
    private var historyURL: URL { baseURL.appendingPathComponent("history.json") }

    // MARK: - Settings

    public func settings() -> BriefingNotificationSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return BriefingNotificationSettings() }
        do {
            return try Self.decoder.decode(BriefingNotificationSettings.self, from: data)
        } catch {
            logger.error("Failed to decode notification settings: \(error.localizedDescription, privacy: .public)")
            return BriefingNotificationSettings()
        }
    }

    public func saveSettings(_ settings: BriefingNotificationSettings) throws {
        try write(Self.encoder.encode(settings), to: settingsURL)
    }

    // MARK: - History

    /// Every recorded notification, newest first.
    public func history() -> [NotificationRecord] {
        if let cachedHistory { return cachedHistory }
        let loaded: [NotificationRecord]
        if let data = try? Data(contentsOf: historyURL) {
            loaded = (try? Self.decoder.decode([NotificationRecord].self, from: data)) ?? []
        } else {
            loaded = []
        }
        cachedHistory = loaded
        return loaded
    }

    public func append(_ record: NotificationRecord) throws {
        var records = history()
        records.insert(record, at: 0)
        if records.count > Self.historyLimit {
            records.removeLast(records.count - Self.historyLimit)
        }
        try write(Self.encoder.encode(records), to: historyURL)
        cachedHistory = records
    }

    public func clearHistory() throws {
        if fileManager.fileExists(atPath: historyURL.path) {
            try fileManager.removeItem(at: historyURL)
        }
        cachedHistory = []
    }

    /// Whether a notification about `briefingId` was already sent.
    public func hasSent(briefingId: UUID) -> Bool {
        history().contains { $0.status == .sent && $0.briefingId == briefingId }
    }

    /// Whether any notification was sent from one of `sessionKeys` at or after
    /// `date` — e.g. by the agent run that published a briefing.
    public func hasSent(fromSessions sessionKeys: Set<String>, since date: Date) -> Bool {
        guard !sessionKeys.isEmpty else { return false }
        return history().contains { record in
            record.status == .sent
                && record.createdAt >= date
                && record.sessionKey.map(sessionKeys.contains) == true
        }
    }

    // MARK: - Helpers

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
