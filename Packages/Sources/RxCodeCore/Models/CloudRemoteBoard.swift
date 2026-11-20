import Foundation

// MARK: - Remote rows

/// A story as Autopilot returns it.
public struct CloudRemoteStory: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let fields: CloudStoryFields
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(id: String, fields: CloudStoryFields, updatedAt: Date? = nil) {
        self.id = id
        self.fields = fields
        self.createdAt = nil
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, createdAt, updatedAt }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(createdAt.map { $0.timeIntervalSince1970 * 1000 }, forKey: .createdAt)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(updatedAt.map { $0.timeIntervalSince1970 * 1000 }, forKey: .updatedAt)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = CloudDate.decode(c, forKey: .createdAt)
        updatedAt = CloudDate.decode(c, forKey: .updatedAt)
        fields = try CloudStoryFields(from: decoder)
    }
}

/// A task as Autopilot returns it.
public struct CloudRemoteTask: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let fields: CloudTaskFields
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(id: String, fields: CloudTaskFields, updatedAt: Date? = nil) {
        self.id = id
        self.fields = fields
        self.createdAt = nil
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, createdAt, updatedAt }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(createdAt.map { $0.timeIntervalSince1970 * 1000 }, forKey: .createdAt)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(updatedAt.map { $0.timeIntervalSince1970 * 1000 }, forKey: .updatedAt)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = CloudDate.decode(c, forKey: .createdAt)
        updatedAt = CloudDate.decode(c, forKey: .updatedAt)
        fields = try CloudTaskFields(from: decoder)
    }
}

/// `GET /api/v1/docs/repositories/{id}/tasks`.
public struct CloudRemoteBoard: Codable, Sendable {
    public var matchesPreviousSnapshot = false
    private enum CodingKeys: String, CodingKey {
        case checkpoint, savedViewsRevision, members, role, currentUserId, stories, tasks
    }
    public var checkpoint: String?
    public var savedViewsRevision: Int?
    public var members: [CardAssignee]?
    public var role: String?
    public var currentUserId: String?
    public var stories: [CloudRemoteStory]
    public var tasks: [CloudRemoteTask]

    public init(stories: [CloudRemoteStory] = [], tasks: [CloudRemoteTask] = []) {
        self.stories = stories
        self.tasks = tasks
    }
}

enum CloudDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Date? {
        if let text = try? c.decodeIfPresent(String.self, forKey: key) {
            return parse(text)
        }
        if let millis = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return nil
    }

    /// Autopilot stores milliseconds and JSON carries ISO text; whole seconds
    /// survive both exactly.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }

    static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
