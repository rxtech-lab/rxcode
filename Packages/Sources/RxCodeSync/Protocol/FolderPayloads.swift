import Foundation
import RxCodeCore

/// A node in the remote folder tree shown by the mobile picker. Carries plain
/// files too when a request set `includeFiles` (e.g. picking a Makefile).
public struct RemoteFolderNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }

    public let name: String
    public let path: String
    public let isSelectable: Bool
    /// `false` for plain files surfaced when a picker requested files. Defaults
    /// to `true` so folder trees from older desktops decode as directories.
    public let isDirectory: Bool
    public let children: [RemoteFolderNode]

    public init(
        name: String,
        path: String,
        isSelectable: Bool = true,
        isDirectory: Bool = true,
        children: [RemoteFolderNode] = []
    ) {
        self.name = name
        self.path = path
        self.isSelectable = isSelectable
        self.isDirectory = isDirectory
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, isSelectable, isDirectory, children
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        isSelectable = try c.decodeIfPresent(Bool.self, forKey: .isSelectable) ?? true
        isDirectory = try c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? true
        children = try c.decodeIfPresent([RemoteFolderNode].self, forKey: .children) ?? []
    }
}

public struct FolderTreeRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    /// `nil` asks the desktop for the picker roots. Non-nil asks for that
    /// folder's immediate children.
    public let path: String?
    public let depth: Int
    public let includeHidden: Bool
    /// When `true` the desktop also lists plain files (not just folders) so the
    /// picker can select a file such as a Makefile.
    public let includeFiles: Bool

    public init(
        clientRequestID: UUID = UUID(),
        path: String? = nil,
        depth: Int = 1,
        includeHidden: Bool = false,
        includeFiles: Bool = false
    ) {
        self.clientRequestID = clientRequestID
        self.path = path
        self.depth = depth
        self.includeHidden = includeHidden
        self.includeFiles = includeFiles
    }

    private enum CodingKeys: String, CodingKey {
        case clientRequestID, path, depth, includeHidden, includeFiles
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientRequestID = try c.decode(UUID.self, forKey: .clientRequestID)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 1
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false
        includeFiles = try c.decodeIfPresent(Bool.self, forKey: .includeFiles) ?? false
    }
}

public struct FolderTreeResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let requestedPath: String?
    public let ok: Bool
    public let root: RemoteFolderNode?
    public let errorMessage: String?

    public init(
        clientRequestID: UUID,
        requestedPath: String?,
        ok: Bool,
        root: RemoteFolderNode? = nil,
        errorMessage: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.requestedPath = requestedPath
        self.ok = ok
        self.root = root
        self.errorMessage = errorMessage
    }
}

public struct CreateProjectRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let path: String

    public init(clientRequestID: UUID = UUID(), path: String) {
        self.clientRequestID = clientRequestID
        self.path = path
    }
}

public struct CreateProjectResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let ok: Bool
    public let project: Project?
    public let errorMessage: String?

    public init(
        clientRequestID: UUID,
        ok: Bool,
        project: Project? = nil,
        errorMessage: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.ok = ok
        self.project = project
        self.errorMessage = errorMessage
    }
}

public struct DeleteProjectRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID

    public init(clientRequestID: UUID = UUID(), projectID: UUID) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
    }
}

public struct DeleteProjectResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let ok: Bool
    public let errorMessage: String?

    public init(
        clientRequestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.ok = ok
        self.errorMessage = errorMessage
    }
}
