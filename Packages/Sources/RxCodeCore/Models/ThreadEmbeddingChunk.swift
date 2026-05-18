import Foundation
import SwiftData

/// Persisted semantic-search chunk for a single thread. A thread is split into
/// one or more chunks at index time, each chunk gets its own embedding, and
/// search ranks chunks then collapses to one hit per thread.
@Model
public final class ThreadEmbeddingChunk {
    @Attribute(.unique) public var id: String
    public var threadId: String
    public var projectId: UUID
    public var chunkIndex: Int
    public var text: String
    /// L2-normalised `[Float]` packed as little-endian bytes. Length == dim * 4.
    public var vector: Data
    public var dim: Int
    public var updatedAt: Date

    public init(
        id: String,
        threadId: String,
        projectId: UUID,
        chunkIndex: Int,
        text: String,
        vector: Data,
        dim: Int,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.threadId = threadId
        self.projectId = projectId
        self.chunkIndex = chunkIndex
        self.text = text
        self.vector = vector
        self.dim = dim
        self.updatedAt = updatedAt
    }

    public static func makeId(threadId: String, index: Int) -> String {
        "\(threadId)#\(index)"
    }
}

extension ThreadEmbeddingChunk {
    /// Decode the persisted `Data` blob back into a `[Float]` of length `dim`.
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
