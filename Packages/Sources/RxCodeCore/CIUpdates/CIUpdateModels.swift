import Foundation

/// One page load, including repository resolution and independently available sections.
public struct CIRepositoryOverview: Codable, Sendable {
    public let repository: WatchedRepo?
    public let history: [CIUpdateRunHistory]?
    public let pullRequests: [CIPullRequest]?
    public let automation: RepositoryAutomationResponse?
    public let errors: [String: String]
}

// Codable DTOs mirroring github-pm's `/api/v1/watched-repositories/*` JSON
// shapes (the "CI auto-update scan" feature). Field names match the server
// responses; extra fields decode harmlessly and uncertain fields are optional
// so a contract drift degrades gracefully rather than failing the whole decode.
//
// Two deliberate differences from the secrets DTOs:
//  - Pagination is top-level (`nextCursor` / `hasMore`), NOT a nested
//    `pagination` object like `SecretsManagedRepoPage`.
//  - Timestamp encoding is INCONSISTENT across endpoints: STATUS emits epoch-ms
//    numbers, while LIST/HISTORY/PRS emit ISO-8601 strings. `FlexibleTimestamp`
//    tolerates both (plus null), so the client doesn't have to special-case it.

// MARK: - Flexible timestamp

/// A timestamp that tolerates every encoding the CI API emits: an ISO-8601
/// string (LIST/HISTORY/PRS), an epoch-milliseconds number (STATUS), or null.
/// Exposes a single `date` accessor regardless of the wire shape.
public struct FlexibleTimestamp: Codable, Sendable, Hashable {
    public let date: Date?

    public init(date: Date? = nil) { self.date = date }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.date = nil
        } else if let ms = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: ms / 1000)
        } else if let string = try? container.decode(String.self) {
            self.date = FlexibleTimestamp.parseISO(string)
        } else {
            self.date = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        } else {
            try container.encodeNil()
        }
    }

    /// ISO8601DateFormatter doesn't accept fractional seconds unless asked, and
    /// the server emits both `…:00.000Z` and `…:00Z` forms — try both. Formatters
    /// are created locally (the parsed lists are small) to stay `Sendable`-clean.
    static func parseISO(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Scan frequency

/// How often autopilot scans a watched repo for outdated CI actions. Decoding is
/// lenient — an unrecognized value falls back to `.weekly` rather than failing
/// the whole list decode.
public enum CIScanFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CIScanFrequency(rawValue: raw) ?? .weekly
    }
}

// MARK: - Watched repository

/// One configured repo from `GET /api/v1/watched-repositories`.
public struct WatchedRepo: Codable, Sendable, Identifiable, Hashable {
    /// Internal watched-repository UUID.
    public let id: String
    public let installationId: Int
    public let repositoryId: Int
    public let repositoryFullName: String
    public let owner: String?
    public let repo: String?
    public let lastScannedAt: FlexibleTimestamp?
    public let scheduleId: String?
    /// Nullable on the wire (column defaults to `"weekly"`); decode leniently and
    /// expose the non-optional `scanFrequency` computed below.
    public let scanFrequencyRaw: CIScanFrequency?
    public let createdAt: FlexibleTimestamp?
    public let updatedAt: FlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case id, installationId, repositoryId, repositoryFullName, owner, repo
        case lastScannedAt, scheduleId
        case scanFrequencyRaw = "scanFrequency"
        case createdAt, updatedAt
    }

    public var fullName: String { repositoryFullName }
    public var scanFrequency: CIScanFrequency { scanFrequencyRaw ?? .weekly }
    public var lastScannedDate: Date? { lastScannedAt?.date }
    public var createdDate: Date? { createdAt?.date }
    public var hasBeenScanned: Bool { lastScannedAt?.date != nil }

    public init(
        id: String,
        installationId: Int,
        repositoryId: Int,
        repositoryFullName: String,
        owner: String? = nil,
        repo: String? = nil,
        lastScannedAt: FlexibleTimestamp? = nil,
        scheduleId: String? = nil,
        scanFrequency: CIScanFrequency = .weekly,
        createdAt: FlexibleTimestamp? = nil,
        updatedAt: FlexibleTimestamp? = nil
    ) {
        self.id = id
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
        self.owner = owner
        self.repo = repo
        self.lastScannedAt = lastScannedAt
        self.scheduleId = scheduleId
        self.scanFrequencyRaw = scanFrequency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `GET /api/v1/watched-repositories` page. NOTE the top-level cursor/hasMore —
/// unlike secrets' nested `pagination` object.
public struct WatchedRepoPage: Codable, Sendable {
    public let repositories: [WatchedRepo]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(repositories: [WatchedRepo], nextCursor: String? = nil, hasMore: Bool = false) {
        self.repositories = repositories
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

// MARK: - Batch status (banner gating)

/// One repo's watch status from `POST /api/v1/watched-repositories/status`.
/// `watchedRepositoryId == nil` means the repo is not yet watched.
public struct CIWatchStatus: Codable, Sendable, Hashable {
    public let repositoryFullName: String
    public let watchedRepositoryId: String?
    public let scanFrequency: CIScanFrequency?
    public let lastScannedAt: FlexibleTimestamp?

    public var isWatched: Bool { watchedRepositoryId != nil }
    public var lastScannedDate: Date? { lastScannedAt?.date }

    public init(
        repositoryFullName: String,
        watchedRepositoryId: String? = nil,
        scanFrequency: CIScanFrequency? = nil,
        lastScannedAt: FlexibleTimestamp? = nil
    ) {
        self.repositoryFullName = repositoryFullName
        self.watchedRepositoryId = watchedRepositoryId
        self.scanFrequency = scanFrequency
        self.lastScannedAt = lastScannedAt
    }
}

public struct CIWatchStatusList: Codable, Sendable {
    public let items: [CIWatchStatus]
}

public struct CIWatchStatusRequest: Codable, Sendable {
    public let repositories: [String]

    public init(repositories: [String]) {
        self.repositories = repositories
    }
}

// MARK: - Mutations

/// Body for `POST /api/v1/watched-repositories` (register a repo to watch).
public struct AddWatchedRepoBody: Codable, Sendable {
    public let installationId: Int
    public let repositoryId: Int
    public let repositoryFullName: String
    public let scanFrequency: CIScanFrequency

    public init(installationId: Int, repositoryId: Int, repositoryFullName: String, scanFrequency: CIScanFrequency) {
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
        self.scanFrequency = scanFrequency
    }
}

/// Body for `PATCH /api/v1/watched-repositories/{id}`.
public struct UpdateScanFrequencyBody: Codable, Sendable {
    public let scanFrequency: CIScanFrequency

    public init(scanFrequency: CIScanFrequency) {
        self.scanFrequency = scanFrequency
    }
}

/// Body for `DELETE /api/v1/watched-repositories/{id}/prs` (close a PR).
public struct ClosePRBody: Codable, Sendable {
    public let prNumber: Int

    public init(prNumber: Int) {
        self.prNumber = prNumber
    }
}

/// `POST /api/v1/watched-repositories/{id}/trigger` result.
public struct CITriggerResponse: Codable, Sendable {
    public let success: Bool
    public let prUrl: String?
    public let error: String?
}

// MARK: - Scan history

/// One scan run from `GET /api/v1/watched-repositories/{id}/history` (a bare
/// array, not an `{ items: [...] }` wrapper). Counts may be nil for error runs.
public struct CIUpdateRunHistory: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let watchedRepositoryId: String?
    /// `"success"` or `"error"`.
    public let status: String
    public let workflowsScanned: Int?
    public let actionsFound: Int?
    public let outdatedActionsCount: Int?
    public let prUrl: String?
    public let prNumber: Int?
    public let errorMessage: String?
    public let startedAt: FlexibleTimestamp?
    public let completedAt: FlexibleTimestamp?

    public var isSuccess: Bool { status == "success" }
    public var startedDate: Date? { startedAt?.date }
    public var completedDate: Date? { completedAt?.date }
}

// MARK: - Pull requests

/// One PR opened by the auto-updater, from
/// `GET /api/v1/watched-repositories/{id}/prs`. GitHub-native field names
/// (`number`, `html_url`, `created_at`, `merged`); all optional so decode
/// degrades gracefully.
public struct CIPullRequest: Codable, Sendable, Identifiable, Hashable {
    public let number: Int?
    public let title: String?
    /// `"open"` or `"closed"` (a merged PR is `"closed"` + `merged: true`).
    public let state: String?
    public let htmlURL: String?
    public let merged: Bool?
    public let createdAt: FlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case number, title, state, merged
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }

    /// Stable identity: PR number when known, else the URL, else the title.
    public var id: String {
        if let number { return "pr-\(number)" }
        if let htmlURL { return htmlURL }
        return title ?? UUID().uuidString
    }

    public var createdDate: Date? { createdAt?.date }
    public var isOpen: Bool { (state ?? "open").lowercased() == "open" }
}

// MARK: - Misc

public struct CIUpdateIDResponse: Codable, Sendable {
    public let id: String
}

/// Accepted dependency scan; completion happens asynchronously on the server.
public struct DependencyScanTriggerResponse: Codable, Sendable {
    public let queued: Bool
    public let runId: String
}

// MARK: - Repository automation (dependency & security scans)

/// Package manager a dependency target is scanned with. Mirrors github-pm's
/// `managers` list; unknown values fall back to `.auto`.
public enum DependencyManager: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, bun, npm, yarn, pnpm, go, swift, python

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto Detect"
        case .bun: return "Bun"
        case .npm: return "npm"
        case .yarn: return "Yarn"
        case .pnpm: return "pnpm"
        case .go: return "Go"
        case .swift: return "Swift"
        case .python: return "Python"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DependencyManager(rawValue: raw) ?? .auto
    }
}

/// One project directory included in dependency scans. `directory` is relative
/// to the repository root; the root itself is the empty string.
public struct DependencyTarget: Codable, Sendable, Hashable {
    public var directory: String
    public var manager: DependencyManager

    public init(directory: String = "", manager: DependencyManager = .auto) {
        self.directory = directory
        self.manager = manager
    }

    public var displayDirectory: String { directory.isEmpty ? "." : directory }
}

/// Per-repository automation settings from
/// `GET/PUT /api/v1/watched-repositories/{id}/automation`. The server schema is
/// strict, so this encodes exactly these keys.
public struct RepositoryAutomationSettings: Codable, Sendable, Hashable {
    public var dependenciesEnabled: Bool
    public var dependencyCiRepair: Bool
    public var dependencyAutoMerge: Bool
    public var ciAutoMerge: Bool
    public var dependencySecurityEnabled: Bool
    public var ciSecurityEnabled: Bool
    public var dependencyNotifications: Bool
    public var ciNotifications: Bool
    public var targets: [DependencyTarget]

    public static let maxTargets = 20

    public init(
        dependenciesEnabled: Bool = false,
        dependencyCiRepair: Bool = true,
        dependencyAutoMerge: Bool = false,
        ciAutoMerge: Bool = false,
        dependencySecurityEnabled: Bool = true,
        ciSecurityEnabled: Bool = true,
        dependencyNotifications: Bool = true,
        ciNotifications: Bool = true,
        targets: [DependencyTarget] = [DependencyTarget()]
    ) {
        self.dependenciesEnabled = dependenciesEnabled
        self.dependencyCiRepair = dependencyCiRepair
        self.dependencyAutoMerge = dependencyAutoMerge
        self.ciAutoMerge = ciAutoMerge
        self.dependencySecurityEnabled = dependencySecurityEnabled
        self.ciSecurityEnabled = ciSecurityEnabled
        self.dependencyNotifications = dependencyNotifications
        self.ciNotifications = ciNotifications
        self.targets = targets
    }

    /// Missing keys take the server defaults so an older payload still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RepositoryAutomationSettings()
        dependenciesEnabled = try c.decodeIfPresent(Bool.self, forKey: .dependenciesEnabled) ?? defaults.dependenciesEnabled
        dependencyCiRepair = try c.decodeIfPresent(Bool.self, forKey: .dependencyCiRepair) ?? defaults.dependencyCiRepair
        dependencyAutoMerge = try c.decodeIfPresent(Bool.self, forKey: .dependencyAutoMerge) ?? defaults.dependencyAutoMerge
        ciAutoMerge = try c.decodeIfPresent(Bool.self, forKey: .ciAutoMerge) ?? defaults.ciAutoMerge
        dependencySecurityEnabled = try c.decodeIfPresent(Bool.self, forKey: .dependencySecurityEnabled) ?? defaults.dependencySecurityEnabled
        ciSecurityEnabled = try c.decodeIfPresent(Bool.self, forKey: .ciSecurityEnabled) ?? defaults.ciSecurityEnabled
        dependencyNotifications = try c.decodeIfPresent(Bool.self, forKey: .dependencyNotifications) ?? defaults.dependencyNotifications
        ciNotifications = try c.decodeIfPresent(Bool.self, forKey: .ciNotifications) ?? defaults.ciNotifications
        targets = try c.decodeIfPresent([DependencyTarget].self, forKey: .targets) ?? defaults.targets
    }

    /// Client-side mirror of the server's directory rule, used to validate
    /// picks before saving: relative, no traversal, no `.git`, no wildcards.
    public static func isValidDirectory(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.count <= 240 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part != ".git"
                && part.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
        }
    }
}

/// A vulnerability reported by a dependency or GitHub Actions security scan.
public struct DependencyVulnerability: Codable, Sendable, Hashable {
    public let id: String
    public let package: String
    public let version: String
    public let path: String
    public let url: String
}

/// One dependency or CI security scan run.
public struct DependencyUpdateRun: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    /// `"dependencies"` or `"ci-security"`.
    public let kind: String
    /// `"queued"`, `"running"`, `"success"` or `"error"`.
    public let status: String
    public let prUrls: [String]?
    public let findings: [DependencyVulnerability]?
    public let error: String?
    public let startedAt: FlexibleTimestamp?
    public let completedAt: FlexibleTimestamp?

    public var isDependencies: Bool { kind == "dependencies" }
    public var isActive: Bool { status == "queued" || status == "running" }
    public var startedDate: Date? { startedAt?.date }
    public var completedDate: Date? { completedAt?.date }
}

/// `GET /api/v1/watched-repositories/{id}/automation`.
public struct RepositoryAutomationResponse: Codable, Sendable {
    public let settings: RepositoryAutomationSettings
    public let runs: [DependencyUpdateRun]
    public let scannerConfigured: Bool

    public init(settings: RepositoryAutomationSettings, runs: [DependencyUpdateRun], scannerConfigured: Bool) {
        self.settings = settings
        self.runs = runs
        self.scannerConfigured = scannerConfigured
    }
}

/// `PUT /api/v1/watched-repositories/{id}/automation`.
public struct RepositoryAutomationSaveResponse: Codable, Sendable {
    public let settings: RepositoryAutomationSettings
    public init(settings: RepositoryAutomationSettings) { self.settings = settings }
}

/// One folder level from `GET /api/v1/watched-repositories/{id}/directories`.
public struct RepositoryDirectoryListing: Codable, Sendable {
    public struct Directory: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public let sha: String
        public var id: String { sha + name }
    }

    public let sha: String
    public let directories: [Directory]
}
