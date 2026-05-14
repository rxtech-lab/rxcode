import Foundation
import SwiftData

/// Persisted queued user message — survives app relaunch.
/// One row per queued message; the in-memory `WindowState.messageQueue` is
/// repopulated from these rows on launch.
@Model
public final class QueuedMessageRecord {
    @Attribute(.unique) public var id: UUID
    /// Either a real session id, or "new" for the not-yet-started chat bucket.
    /// Matches the keying scheme used by `WindowState.draftQueues`.
    public var sessionKey: String
    public var order: Int
    public var text: String
    public var attachmentsData: Data
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionKey: String,
        order: Int,
        text: String,
        attachmentsData: Data,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.order = order
        self.text = text
        self.attachmentsData = attachmentsData
        self.createdAt = createdAt
    }
}

extension QueuedMessageRecord {
    public static func encodeAttachments(_ attachments: [Attachment]) -> Data {
        let dtos = attachments.map(\.dto)
        return (try? JSONEncoder().encode(dtos)) ?? Data()
    }

    public static func decodeAttachments(_ data: Data) -> [Attachment] {
        guard !data.isEmpty,
              let dtos = try? JSONDecoder().decode([Attachment.DTO].self, from: data) else {
            return []
        }
        return dtos.map(Attachment.init(dto:))
    }

    public func toQueuedMessage() -> QueuedMessage {
        QueuedMessage(
            id: id,
            text: text,
            attachments: Self.decodeAttachments(attachmentsData)
        )
    }
}
