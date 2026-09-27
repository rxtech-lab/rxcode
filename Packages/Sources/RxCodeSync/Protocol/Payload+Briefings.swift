import Foundation

/// Lightweight metadata in each snapshot. Bodies and files are fetched when opened.
public struct MobileBriefingDocument: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let format: String
    public let projectId: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID, title: String, format: String, projectId: UUID?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.format = format
        self.projectId = projectId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MobileBriefingAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let byteCount: Int64

    public init(path: String, byteCount: Int64) {
        self.path = path
        self.byteCount = byteCount
    }
}

public struct BriefingContentRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let briefingID: UUID
    /// A folder-relative asset path. Nil requests the body and asset list.
    public let assetPath: String?
    /// Byte position for a file chunk. Nil starts at the beginning.
    public let assetOffset: Int64?

    public init(clientRequestID: UUID, briefingID: UUID, assetPath: String? = nil, assetOffset: Int64? = nil) {
        self.clientRequestID = clientRequestID
        self.briefingID = briefingID
        self.assetPath = assetPath
        self.assetOffset = assetOffset
    }
}

public struct BriefingContentResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let briefingID: UUID
    public let assetPath: String?
    public let ok: Bool
    public let errorMessage: String?
    public let content: String?
    public let assets: [MobileBriefingAsset]?
    /// Base64 encoded bytes for an explicitly requested asset.
    public let assetBase64: String?
    public let assetOffset: Int64?
    public let assetTotalBytes: Int64?

    public init(clientRequestID: UUID, briefingID: UUID, assetPath: String? = nil, ok: Bool,
                errorMessage: String? = nil, content: String? = nil,
                assets: [MobileBriefingAsset]? = nil, assetBase64: String? = nil,
                assetOffset: Int64? = nil, assetTotalBytes: Int64? = nil) {
        self.clientRequestID = clientRequestID
        self.briefingID = briefingID
        self.assetPath = assetPath
        self.ok = ok
        self.errorMessage = errorMessage
        self.content = content
        self.assets = assets
        self.assetBase64 = assetBase64
        self.assetOffset = assetOffset
        self.assetTotalBytes = assetTotalBytes
    }
}
