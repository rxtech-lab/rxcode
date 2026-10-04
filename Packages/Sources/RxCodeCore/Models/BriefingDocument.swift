import Foundation
import UniformTypeIdentifiers

/// The kinds of briefing RxCode shows in the briefing tab.
public enum BriefingKind: String, Codable, Sendable, CaseIterable {
    /// The auto-generated per-branch project summary (`BranchBriefingRecord`),
    /// persisted in SwiftData.
    case project
    /// A standalone briefing written by an agent. Stored locally in its own
    /// folder together with its content and assets (see `BriefingStore`).
    case document
}

/// The markup language a document briefing's content is written in.
public enum BriefingContentFormat: String, Codable, Sendable, CaseIterable {
    case markdown
    case html

    /// File name of the content file inside the briefing folder.
    public var contentFileName: String {
        switch self {
        case .markdown: "content.md"
        case .html: "content.html"
        }
    }
}

/// Categories of files stored alongside a briefing's content. Each category
/// has its own subfolder inside the briefing folder.
public enum BriefingAssetKind: String, Codable, Sendable, CaseIterable {
    case image
    case video
    case file

    public var directoryName: String {
        switch self {
        case .image: "images"
        case .video: "videos"
        case .file: "files"
        }
    }

    /// Infers the asset category from a file name's extension.
    public static func inferred(fromFileName fileName: String) -> BriefingAssetKind {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }
}

/// A file stored in a briefing folder.
public struct BriefingAsset: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { relativePath }

    public let kind: BriefingAssetKind
    public let fileName: String
    public let byteCount: Int64

    /// Path relative to the briefing folder, e.g. `images/chart.png`. Content
    /// files reference assets with this path.
    public var relativePath: String { "\(kind.directoryName)/\(fileName)" }

    /// Parses a folder-relative path such as `images/chart.png`. Returns nil
    /// when the folder is not an asset folder or the path is nested deeper.
    public init?(relativePath: String, byteCount: Int64 = 0) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = BriefingAssetKind.allCases.first(where: { $0.directoryName == parts[0] }),
              !parts[1].isEmpty
        else { return nil }
        self.init(kind: kind, fileName: String(parts[1]), byteCount: byteCount)
    }

    public init(kind: BriefingAssetKind, fileName: String, byteCount: Int64) {
        self.kind = kind
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

/// Metadata for a document briefing. Persisted as `briefing.json` inside the
/// briefing's folder; the content and assets live next to it on disk.
public struct BriefingDocument: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var kind: BriefingKind
    public var title: String
    public var format: BriefingContentFormat
    /// Project the briefing relates to, if any.
    public var projectId: UUID?
    public let createdAt: Date
    public var updatedAt: Date
    /// Drafts are still being written by an agent and are hidden from the
    /// briefing timeline until published.
    public var isDraft: Bool
    /// When the briefing was last published; nil while it is a draft.
    public var publishedAt: Date?

    public var isPublished: Bool { !isDraft }

    public init(
        id: UUID = UUID(),
        title: String,
        format: BriefingContentFormat = .markdown,
        projectId: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        isDraft: Bool = false
    ) {
        self.id = id
        self.kind = .document
        self.title = title
        self.format = format
        self.projectId = projectId
        self.createdAt = Self.timestamp(createdAt)
        self.updatedAt = Self.timestamp(updatedAt ?? createdAt)
        self.isDraft = isDraft
        self.publishedAt = isDraft ? nil : self.createdAt
    }

    /// Rounds a date down to whole seconds — the precision the ISO-8601
    /// manifest stores — so in-memory values match what is read back.
    public static func timestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, format, projectId, createdAt, updatedAt, isDraft, publishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(BriefingKind.self, forKey: .kind) ?? .document
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        format = try container.decodeIfPresent(BriefingContentFormat.self, forKey: .format) ?? .markdown
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        // Manifests written before drafts existed are treated as published.
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt) ?? (isDraft ? nil : createdAt)
    }
}
