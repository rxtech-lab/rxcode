import Foundation

// Codable DTOs mirroring github-pm's `/api/v1/secrets/*` JSON shapes.
// Field names match the server responses; extra fields decode harmlessly.

// MARK: - Enrollment / user key

public struct SecretsUserKey: Codable, Sendable {
    public let enrolled: Bool
    public let publicKey: String?
    public let wrappedPrivateKey: String?
    public let wrapIv: String?
    public let algorithm: String?

    public init(
        enrolled: Bool,
        publicKey: String? = nil,
        wrappedPrivateKey: String? = nil,
        wrapIv: String? = nil,
        algorithm: String? = nil
    ) {
        self.enrolled = enrolled
        self.publicKey = publicKey
        self.wrappedPrivateKey = wrappedPrivateKey
        self.wrapIv = wrapIv
        self.algorithm = algorithm
    }
}

public struct EnrollKeyBody: Codable, Sendable {
    public let publicKey: String
    public let wrappedPrivateKey: String
    public let wrapIv: String
    public let algorithm: String

    public init(publicKey: String, wrappedPrivateKey: String, wrapIv: String, algorithm: String = "ECDH-P256") {
        self.publicKey = publicKey
        self.wrappedPrivateKey = wrappedPrivateKey
        self.wrapIv = wrapIv
        self.algorithm = algorithm
    }
}

// MARK: - Repositories (new `/repositories/all` endpoint)

public struct SecretsManagedRepo: Codable, Sendable, Identifiable, Hashable {
    public let id: Int // GitHub repository id
    public let fullName: String
    public let name: String
    public let owner: String
    public let isPrivate: Bool
    public let defaultBranch: String
    public let secretsRepoId: String? // internal secrets UUID when managed
    public let installationId: Int
    public let environmentsCount: Int
    public let filesCount: Int
    public let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case id, fullName, name, owner
        case isPrivate = "private"
        case defaultBranch, secretsRepoId, installationId
        case environmentsCount, filesCount, isCurrent
    }

    public var isManaged: Bool { secretsRepoId != nil }
}

public struct SecretsManagedRepoPage: Codable, Sendable {
    public let items: [SecretsManagedRepo]
    public let pagination: Pagination

    public struct Pagination: Codable, Sendable {
        public let nextCursor: String?
        public let hasMore: Bool
    }
}

// MARK: - Repository secrets status (batch)

/// One repo's secrets-management status from `POST /repositories/status`.
public struct SecretsRepoStatus: Codable, Sendable, Hashable {
    public let fullName: String
    public let secretsRepoId: String?
    public let isManaged: Bool
    public let environmentsCount: Int
    public let filesCount: Int
}

public struct SecretsRepoStatusList: Codable, Sendable {
    public let items: [SecretsRepoStatus]
}

public struct SecretsRepoStatusRequest: Codable, Sendable {
    public let repositories: [String]

    public init(repositories: [String]) {
        self.repositories = repositories
    }
}

public struct AddSecretsRepoBody: Codable, Sendable {
    public let installationId: Int
    public let repositoryId: Int
    public let repositoryFullName: String

    public init(installationId: Int, repositoryId: Int, repositoryFullName: String) {
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
    }
}

// MARK: - Environments

public struct SecretsEnvironment: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let filesCount: Int?

    public init(id: String, name: String, filesCount: Int? = nil) {
        self.id = id
        self.name = name
        self.filesCount = filesCount
    }
}

public struct SecretsEnvironmentList: Codable, Sendable {
    public let items: [SecretsEnvironment]
}

public struct EnvironmentKeyBody: Codable, Sendable {
    public let wrapMode: String
    public let wrappedDek: String
    public let wrapIv: String?
    public let ephemeralPublicKey: String?

    public init(wrapMode: String, wrappedDek: String, wrapIv: String?, ephemeralPublicKey: String?) {
        self.wrapMode = wrapMode
        self.wrappedDek = wrappedDek
        self.wrapIv = wrapIv
        self.ephemeralPublicKey = ephemeralPublicKey
    }
}

public struct CreateEnvironmentBody: Codable, Sendable {
    public let name: String
    public let ownerKey: EnvironmentKeyBody

    public init(name: String, ownerKey: EnvironmentKeyBody) {
        self.name = name
        self.ownerKey = ownerKey
    }
}

// MARK: - Files

public struct SecretsFileMeta: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let filename: String
    public let size: Int?
    public let encryptedByUserId: String?
}

public struct SecretsFileList: Codable, Sendable {
    public let items: [SecretsFileMeta]
}

// MARK: - Cross-environment filename search

/// One environment that contains a file matching the searched filename.
public struct SecretsFileLocation: Codable, Sendable, Identifiable, Hashable {
    public let environmentId: String
    public let environmentName: String
    public let fileId: String
    public let size: Int?
    public let updatedAt: Double?

    public var id: String { environmentId }
}

/// Result of searching a repo's environments for a given filename, from
/// `GET /repositories/{id}/files?filename=…`.
public struct SecretsFileSearch: Codable, Sendable, Identifiable {
    public let filename: String
    public let environments: [SecretsFileLocation]
    public let exists: Bool

    public var id: String { filename }
}

public struct SecretsFileSearchList: Codable, Sendable {
    public let items: [SecretsFileSearch]
}

public struct UpsertFileBody: Codable, Sendable {
    public let filename: String
    public let ciphertext: String
    public let iv: String
    public let size: Int?

    public init(filename: String, ciphertext: String, iv: String, size: Int?) {
        self.filename = filename
        self.ciphertext = ciphertext
        self.iv = iv
        self.size = size
    }
}

// MARK: - Download bundle

public struct SecretsEnvironmentKey: Codable, Sendable {
    public let wrapMode: String // "kek" | "hpke"
    public let wrappedDek: String
    public let wrapIv: String?
    public let ephemeralPublicKey: String?
}

public struct SecretsBundleFile: Codable, Sendable, Identifiable, Hashable {
    public let filename: String
    public let ciphertext: String
    public let iv: String
    public let size: Int?

    public var id: String { filename }
}

public struct SecretsBundle: Codable, Sendable {
    public let environmentKey: SecretsEnvironmentKey
    public let files: [SecretsBundleFile]
}

// MARK: - Misc

public struct SecretsIDResponse: Codable, Sendable {
    public let id: String
}
