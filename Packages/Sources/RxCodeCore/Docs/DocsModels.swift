import Foundation

// Codable DTOs mirroring github-pm's `/api/v1/docs/*` JSON shapes. Field names
// match the server responses; extra fields decode harmlessly and uncertain
// fields are optional so a contract drift degrades gracefully rather than
// failing the whole decode.

// MARK: - Search

/// One hit from `GET /api/v1/docs/search?q=&repository=&repo=&limit=`. Field
/// names match the server's contract verbatim.
public struct DocsSearchHit: Codable, Sendable, Identifiable, Hashable {
    /// Internal document UUID.
    public let documentId: String?
    /// The logical document id (the frontmatter `slug` the doc was uploaded as).
    public let docId: String
    /// Internal docs-repository UUID.
    public let docsRepositoryId: String?
    /// The repo this doc belongs to, as `owner/repo`.
    public let repositoryFullName: String?
    public let version: Int?
    /// Cosine similarity in 0...1.
    public let similarity: Double?
    /// Short highlighted excerpt around the match (server returns ~240 chars).
    public let snippet: String?
    /// Canonical URL for the source document, when known.
    public let originalLink: String?

    public var id: String { documentId ?? "\(repositoryFullName ?? ""):\(docId)" }

    // Display aliases used across the UI / tools.
    public var repository: String? { repositoryFullName }
    public var score: Double? { similarity }
    /// No dedicated title field in the contract — fall back to the doc id.
    public var title: String? { nil }

    public init(
        documentId: String? = nil,
        docId: String,
        docsRepositoryId: String? = nil,
        repositoryFullName: String? = nil,
        version: Int? = nil,
        similarity: Double? = nil,
        snippet: String? = nil,
        originalLink: String? = nil
    ) {
        self.documentId = documentId
        self.docId = docId
        self.docsRepositoryId = docsRepositoryId
        self.repositoryFullName = repositoryFullName
        self.version = version
        self.similarity = similarity
        self.snippet = snippet
        self.originalLink = originalLink
    }
}

public struct DocsSearchResult: Codable, Sendable {
    public let items: [DocsSearchHit]

    public init(items: [DocsSearchHit]) { self.items = items }
}

// MARK: - Repositories

/// A docs-managed repository from `GET /api/v1/docs/repositories`.
public struct DocsRepo: Codable, Sendable, Identifiable, Hashable {
    /// Internal docs-repository UUID.
    public let id: String
    public let installationId: Int?
    public let repositoryId: Int?
    public let repositoryFullName: String
    public let owner: String?
    public let repo: String?
    public let lastIndexedAt: String?
    public let documentsCount: Int?
    public let createdAt: String?
    public let updatedAt: String?

    public var fullName: String { repositoryFullName }

    public init(
        id: String,
        installationId: Int? = nil,
        repositoryId: Int? = nil,
        repositoryFullName: String,
        owner: String? = nil,
        repo: String? = nil,
        lastIndexedAt: String? = nil,
        documentsCount: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
        self.owner = owner
        self.repo = repo
        self.lastIndexedAt = lastIndexedAt
        self.documentsCount = documentsCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DocsRepoListResponse: Codable, Sendable {
    public let items: [DocsRepo]
    public let pagination: Pagination?

    public struct Pagination: Codable, Sendable {
        public let nextCursor: String?
        public let hasMore: Bool
    }
}

/// Body for `POST /api/v1/docs/repositories` (register a repo for docs).
public struct AddDocsRepoBody: Codable, Sendable {
    public let installationId: Int
    public let repositoryId: Int
    public let repositoryFullName: String

    public init(installationId: Int, repositoryId: Int, repositoryFullName: String) {
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
    }
}

// MARK: - "contains docs" status

/// Whether a repo has docs set up. There is no batch-status endpoint server
/// side; `DocsService.statuses(forRepos:)` derives this from the managed
/// repositories listing (`GET /api/v1/docs/repositories`).
public struct DocsRepoStatus: Codable, Sendable, Hashable {
    /// `owner/repo` the status is for.
    public let repository: String
    public let hasDocs: Bool
    public let documentsCount: Int?
    public let readyCount: Int?
    public let docsRepositoryId: String?

    public init(
        repository: String,
        hasDocs: Bool,
        documentsCount: Int? = nil,
        readyCount: Int? = nil,
        docsRepositoryId: String? = nil
    ) {
        self.repository = repository
        self.hasDocs = hasDocs
        self.documentsCount = documentsCount
        self.readyCount = readyCount
        self.docsRepositoryId = docsRepositoryId
    }
}

// MARK: - Documents

/// One document in a repo from `GET /api/v1/docs/repositories/{id}/documents`.
public struct DocsDocument: Codable, Sendable, Identifiable, Hashable {
    public let docId: String
    public let title: String?
    /// `pending | indexing | ready | failed` per the server's embedding pipeline.
    public let embeddingStatus: String?
    public let updatedAt: String?

    public var id: String { docId }
}

public struct DocsDocumentList: Codable, Sendable {
    public let items: [DocsDocument]
    public let pagination: Pagination?

    public struct Pagination: Codable, Sendable {
        public let nextCursor: String?
        public let hasMore: Bool
    }
}

/// One document in the batch body for
/// `POST /api/v1/docs/repositories/{id}/documents`. `docId` is the logical
/// slug (must be non-empty and unique within the repo); `originalLink`, when
/// present, must be a valid http(s) URL.
public struct DocsDocumentUpload: Codable, Sendable {
    public let docId: String
    public let content: String
    public let originalLink: String?

    public init(docId: String, content: String, originalLink: String? = nil) {
        self.docId = docId
        self.content = content
        self.originalLink = originalLink
    }
}

public struct UploadDocumentsBody: Codable, Sendable {
    public let documents: [DocsDocumentUpload]

    public init(documents: [DocsDocumentUpload]) { self.documents = documents }
}

/// Result of a batch upload. Uploads are async: `jobId` identifies the
/// embedding job and the doc(s) become searchable once it finishes.
public struct DocsUploadResult: Codable, Sendable {
    public let jobId: String?
    public let accepted: Int?
    public let skipped: Int?
    public let total: Int?
}

// MARK: - Single document + versions

/// One stored version of a document. Used both in the version-list response
/// (where `content` is omitted) and as the single-version response (where
/// `content` carries that version's full markdown). Versions are integers,
/// 1-based, returned newest-first.
public struct DocsDocumentVersion: Codable, Sendable, Identifiable, Hashable {
    public let id: String?
    public let documentId: String?
    public let version: Int
    public let content: String?
    public let contentHash: String?
    public let embeddingStatus: String?
    public let embeddingError: String?
    public let createdAt: String?
    public let embeddedAt: String?
}

public struct DocsDocumentVersionList: Codable, Sendable {
    public let items: [DocsDocumentVersion]
}

/// `GET /api/v1/docs/repositories/{id}/documents/{docId}` wraps the document
/// row and its current version. The markdown lives on `currentVersion.content`,
/// not on `document`.
public struct DocsDocumentDetail: Codable, Sendable {
    public let document: Document
    public let currentVersion: DocsDocumentVersion?

    public struct Document: Codable, Sendable {
        public let id: String?
        public let docsRepositoryId: String?
        public let docId: String
        public let originalLink: String?
        public let currentVersionId: String?
        public let currentVersion: Int?
        public let createdAt: String?
        public let updatedAt: String?
    }
}

// MARK: - Upload tokens (CI / machine auth)

/// Result of `POST /api/v1/docs/repositories/{id}/upload-tokens`. The plaintext
/// token is returned exactly once at creation time.
public struct DocsUploadToken: Codable, Sendable {
    public let id: String?
    /// Plaintext upload token (e.g. `dput_…`). Present only on creation.
    public let plaintext: String?
    /// 12-char display prefix for later identification.
    public let tokenPrefix: String?

    /// Convenience alias for the one-time plaintext token.
    public var token: String? { plaintext }
}

public struct CreateDocsUploadTokenBody: Codable, Sendable {
    /// Required, non-empty display name for the token.
    public let name: String

    public init(name: String) { self.name = name }
}

/// Result of `POST /api/v1/docs/repositories/{id}/github-secret`, which mints a
/// `DOCS_UPLOAD_TOKEN` and installs it as the repo's GitHub Actions secret in
/// one step. The plaintext token never leaves the server, so only the secret
/// name and target repo come back.
public struct DocsGithubSecretResult: Codable, Sendable {
    public let secretName: String
    public let repositoryFullName: String

    public init(secretName: String, repositoryFullName: String) {
        self.secretName = secretName
        self.repositoryFullName = repositoryFullName
    }
}

// MARK: - Misc

public struct DocsIDResponse: Codable, Sendable {
    public let id: String
}
