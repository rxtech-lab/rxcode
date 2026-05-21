import Foundation
import SwiftData

public struct MemoryItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let content: String
    public let projectId: UUID?
    public let sessionId: String?
    public let sourceMessageId: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    public let lastUsedAt: Date?
    public let kind: String
    public let scope: String

    public init(
        id: String,
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date?,
        kind: String,
        scope: String
    ) {
        self.id = id
        self.content = content
        self.projectId = projectId
        self.sessionId = sessionId
        self.sourceMessageId = sourceMessageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.kind = kind
        self.scope = scope
    }
}

public struct MemoryVectorSnapshot: Sendable, Equatable {
    public let item: MemoryItem
    public let vector: Data
    public let dim: Int

    public init(item: MemoryItem, vector: Data, dim: Int) {
        self.item = item
        self.vector = vector
        self.dim = dim
    }

    public func floatVector() -> [Float] {
        let count = vector.count / MemoryLayout<Float>.size
        guard count == dim else { return [] }
        return vector.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
    }
}

@Model
public final class MemoryRecord {
    @Attribute(.unique) public var id: String
    public var content: String
    public var projectId: UUID?
    public var sessionId: String?
    public var sourceMessageId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var kind: String
    public var scope: String
    /// L2-normalised `[Float]` packed as little-endian bytes. Length == dim * 4.
    public var vector: Data
    public var dim: Int

    public init(
        id: String = UUID().uuidString,
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        kind: String = "fact",
        scope: String = "project",
        vector: Data,
        dim: Int
    ) {
        self.id = id
        self.content = content
        self.projectId = projectId
        self.sessionId = sessionId
        self.sourceMessageId = sourceMessageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.kind = kind
        self.scope = scope
        self.vector = vector
        self.dim = dim
    }

    public func apply(
        content: String,
        projectId: UUID?,
        sessionId: String?,
        sourceMessageId: UUID?,
        kind: String,
        scope: String,
        vector: Data,
        dim: Int,
        updatedAt: Date = .now
    ) {
        self.content = content
        self.projectId = projectId
        self.sessionId = sessionId
        self.sourceMessageId = sourceMessageId
        self.kind = kind
        self.scope = scope
        self.vector = vector
        self.dim = dim
        self.updatedAt = updatedAt
    }

    public func touch(at date: Date = .now) {
        lastUsedAt = date
    }

    public func toItem() -> MemoryItem {
        MemoryItem(
            id: id,
            content: content,
            projectId: projectId,
            sessionId: sessionId,
            sourceMessageId: sourceMessageId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            kind: kind,
            scope: scope
        )
    }

    public func toVectorSnapshot() -> MemoryVectorSnapshot {
        MemoryVectorSnapshot(item: toItem(), vector: vector, dim: dim)
    }
}

extension MemoryRecord {
    public func floatVector() -> [Float] {
        let count = vector.count / MemoryLayout<Float>.size
        guard count == dim else { return [] }
        return vector.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
    }

    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
