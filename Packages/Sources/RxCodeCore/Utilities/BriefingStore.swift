import Foundation
import os

public enum BriefingStoreError: Error, Equatable, LocalizedError {
    case notFound(UUID)
    case invalidFileName(String)
    case assetNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "Briefing \(id.uuidString) was not found."
        case .invalidFileName(let name): "\"\(name)\" is not a valid file name."
        case .assetNotFound(let path): "Briefing file \"\(path)\" was not found."
        }
    }
}

/// File-backed storage for document briefings. Each briefing gets its own
/// folder:
///
/// ```
/// briefings/{id}/
///   briefing.json          metadata (title, format, creation time, …)
///   content.md | .html     the briefing body
///   images/  videos/  files/
/// ```
///
/// Project (branch) briefings are not stored here; they stay in SwiftData as
/// `BranchBriefingRecord`.
public actor BriefingStore {
    public static let manifestFileName = "briefing.json"

    public nonisolated let baseURL: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.claudework", category: "BriefingStore")

    public init(baseURL: URL = AppSupport.bundleScopedURL.appendingPathComponent("briefings", isDirectory: true)) {
        self.baseURL = baseURL
    }

    // MARK: - Paths

    public nonisolated func folderURL(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public nonisolated func contentURL(for briefing: BriefingDocument) -> URL {
        folderURL(for: briefing.id).appendingPathComponent(briefing.format.contentFileName)
    }

    public nonisolated func assetURL(_ asset: BriefingAsset, in id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent(asset.relativePath)
    }

    private func manifestURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent(Self.manifestFileName)
    }

    // MARK: - Briefings

    /// Creates a briefing folder with its manifest, content file, and empty
    /// asset folders. Pass `isDraft` to keep it hidden until `publish(_:)`.
    @discardableResult
    public func create(
        title: String,
        content: String,
        format: BriefingContentFormat = .markdown,
        projectId: UUID? = nil,
        createdAt: Date = .now,
        isDraft: Bool = false
    ) throws -> BriefingDocument {
        let briefing = BriefingDocument(
            title: title, format: format, projectId: projectId, createdAt: createdAt, isDraft: isDraft
        )
        let folder = folderURL(for: briefing.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for kind in BriefingAssetKind.allCases {
            try fileManager.createDirectory(
                at: folder.appendingPathComponent(kind.directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data(content.utf8).write(to: contentURL(for: briefing), options: .atomic)
        try writeManifest(briefing)
        return briefing
    }

    /// All stored briefings, newest first. Folders with a missing or
    /// unreadable manifest are skipped.
    public func list() -> [BriefingDocument] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders
            .compactMap { folder -> BriefingDocument? in
                guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
                return try? load(id)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func load(_ id: UUID) throws -> BriefingDocument {
        let url = manifestURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw BriefingStoreError.notFound(id) }
        do {
            return try Self.decoder.decode(BriefingDocument.self, from: Data(contentsOf: url))
        } catch {
            logger.error("Failed to decode briefing \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func content(of id: UUID) throws -> String {
        let briefing = try load(id)
        let url = contentURL(for: briefing)
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Replaces the briefing body. Passing a different `format` switches the
    /// content file (e.g. `content.md` → `content.html`).
    @discardableResult
    public func updateContent(
        of id: UUID,
        content: String,
        format: BriefingContentFormat? = nil,
        updatedAt: Date = .now
    ) throws -> BriefingDocument {
        var briefing = try load(id)
        let previousURL = contentURL(for: briefing)
        if let format { briefing.format = format }
        let newURL = contentURL(for: briefing)
        try Data(content.utf8).write(to: newURL, options: .atomic)
        if previousURL != newURL, fileManager.fileExists(atPath: previousURL.path) {
            try fileManager.removeItem(at: previousURL)
        }
        briefing.updatedAt = BriefingDocument.timestamp(updatedAt)
        try writeManifest(briefing)
        return briefing
    }

    @discardableResult
    public func updateTitle(of id: UUID, to title: String, updatedAt: Date = .now) throws -> BriefingDocument {
        var briefing = try load(id)
        briefing.title = title
        briefing.updatedAt = BriefingDocument.timestamp(updatedAt)
        try writeManifest(briefing)
        return briefing
    }

    /// Publishes a draft (or re-publishes an updated briefing), stamping
    /// `publishedAt`.
    @discardableResult
    public func publish(_ id: UUID, at date: Date = .now) throws -> BriefingDocument {
        var briefing = try load(id)
        let stamp = BriefingDocument.timestamp(date)
        briefing.isDraft = false
        briefing.publishedAt = stamp
        briefing.updatedAt = stamp
        try writeManifest(briefing)
        return briefing
    }

    /// Returns a published briefing to draft state.
    @discardableResult
    public func unpublish(_ id: UUID, at date: Date = .now) throws -> BriefingDocument {
        var briefing = try load(id)
        briefing.isDraft = true
        briefing.publishedAt = nil
        briefing.updatedAt = BriefingDocument.timestamp(date)
        try writeManifest(briefing)
        return briefing
    }

    /// Removes the briefing folder and everything in it.
    public func delete(_ id: UUID) throws {
        let folder = folderURL(for: id)
        guard fileManager.fileExists(atPath: folder.path) else { throw BriefingStoreError.notFound(id) }
        try fileManager.removeItem(at: folder)
    }

    // MARK: - Assets

    /// Images, videos, and files stored with a briefing, grouped in that
    /// order and sorted by name.
    public func assets(of id: UUID) throws -> [BriefingAsset] {
        _ = try load(id)
        let folder = folderURL(for: id)
        return BriefingAssetKind.allCases.flatMap { kind -> [BriefingAsset] in
            let directory = folder.appendingPathComponent(kind.directoryName, isDirectory: true)
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { url -> BriefingAsset? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return BriefingAsset(kind: kind, fileName: url.lastPathComponent, byteCount: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
    }

    /// Writes `data` as an asset. The kind is inferred from the file
    /// extension when not given. Existing names get a numeric suffix unless
    /// `overwrite` is set.
    @discardableResult
    public func addAsset(
        to id: UUID,
        fileName: String,
        data: Data,
        kind: BriefingAssetKind? = nil,
        overwrite: Bool = false
    ) throws -> BriefingAsset {
        let (directory, finalName, kind) = try prepareAssetDestination(
            id: id, fileName: fileName, kind: kind, overwrite: overwrite
        )
        try data.write(to: directory.appendingPathComponent(finalName), options: .atomic)
        try touch(id)
        return BriefingAsset(kind: kind, fileName: finalName, byteCount: Int64(data.count))
    }

    /// Copies a file from disk into the briefing as an asset.
    @discardableResult
    public func addAsset(
        to id: UUID,
        copying sourceURL: URL,
        fileName: String? = nil,
        kind: BriefingAssetKind? = nil,
        overwrite: Bool = false
    ) throws -> BriefingAsset {
        let (directory, finalName, kind) = try prepareAssetDestination(
            id: id, fileName: fileName ?? sourceURL.lastPathComponent, kind: kind, overwrite: overwrite
        )
        let destination = directory.appendingPathComponent(finalName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try touch(id)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return BriefingAsset(kind: kind, fileName: finalName, byteCount: Int64(size))
    }

    public func removeAsset(_ asset: BriefingAsset, from id: UUID) throws {
        _ = try load(id)
        _ = try Self.sanitizedFileName(asset.fileName)
        let url = assetURL(asset, in: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BriefingStoreError.assetNotFound(asset.relativePath)
        }
        try fileManager.removeItem(at: url)
        try touch(id)
    }

    // MARK: - Helpers

    private func prepareAssetDestination(
        id: UUID,
        fileName: String,
        kind: BriefingAssetKind?,
        overwrite: Bool
    ) throws -> (URL, String, BriefingAssetKind) {
        _ = try load(id)
        let name = try Self.sanitizedFileName(fileName)
        let kind = kind ?? BriefingAssetKind.inferred(fromFileName: name)
        let directory = folderURL(for: id).appendingPathComponent(kind.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalName = overwrite ? name : uniqueFileName(name, in: directory)
        return (directory, finalName, kind)
    }

    private func uniqueFileName(_ name: String, in directory: URL) -> String {
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
    }

    private func touch(_ id: UUID) throws {
        var briefing = try load(id)
        briefing.updatedAt = BriefingDocument.timestamp(.now)
        try writeManifest(briefing)
    }

    private func writeManifest(_ briefing: BriefingDocument) throws {
        try Self.encoder.encode(briefing).write(to: manifestURL(for: briefing.id), options: .atomic)
    }

    /// Rejects names that could escape the asset folder or clash with the
    /// briefing's own files.
    static func sanitizedFileName(_ fileName: String) throws -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":"),
              !trimmed.contains("\0")
        else { throw BriefingStoreError.invalidFileName(fileName) }
        return trimmed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
