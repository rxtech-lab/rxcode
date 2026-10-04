import Foundation
import RxCodeCore

nonisolated struct StorageBreakdown: Sendable, Equatable {
    var attachments: Int64 = 0
    var sessions: Int64 = 0
    var threadDatabase: Int64 = 0
    var workspaces: Int64 = 0
    var diagnostics: Int64 = 0
    var clearableFiles: Int64 = 0
    var other: Int64 = 0

    var retainedBytes: Int64 {
        attachments + sessions + threadDatabase + workspaces + diagnostics + other
    }

    var totalBytes: Int64 { retainedBytes + clearableFiles }
}

/// Measures RxCode-owned disk storage and removes briefing files and caches.
actor CacheStorageService {
    static let shared = CacheStorageService()

    private let fileManager = FileManager.default
    private let appSupportRoot: URL
    private let cacheRoot: URL
    private let compiledCacheRoots: [URL]

    init(
        appSupportRoot: URL = AppSupport.bundleScopedURL,
        cacheRoot: URL? = nil,
        compiledCacheRoots: [URL]? = nil
    ) {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RxCode", isDirectory: true)
        self.appSupportRoot = appSupportRoot
        self.cacheRoot = cacheRoot ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RxCode", isDirectory: true)
        self.compiledCacheRoots = compiledCacheRoots ?? ["menu-conditions", "task-filters"].map {
            support.appendingPathComponent($0, isDirectory: true)
        }
    }

    func occupiedBytes() -> Int64 { breakdown().totalBytes }

    func breakdown() -> StorageBreakdown {
        var result = StorageBreakdown()
        scanFiles(at: appSupportRoot) { url, bytes in
            let relativePath = url.path.dropFirst(appSupportRoot.path.count + 1)
            let parts = relativePath.split(separator: "/")
            guard let first = parts.first else { return }
            if parts.contains("briefings") || parts.contains("menu-conditions") || parts.contains("task-filters") {
                result.clearableFiles += bytes
            } else if parts.contains("attachments") {
                result.attachments += bytes
            } else if parts.contains("sessions") || parts.contains("session-meta") || parts.contains("global-chat") {
                result.sessions += bytes
            } else if parts.last?.hasPrefix("threads.store") == true {
                result.threadDatabase += bytes
            } else if parts.contains("diagnostics") {
                result.diagnostics += bytes
            } else if first == "workspaces" || parts.contains("task_board") {
                result.workspaces += bytes
            } else {
                result.other += bytes
            }
        }
        scanFiles(at: cacheRoot) { _, bytes in result.clearableFiles += bytes }

        let supportPath = appSupportRoot.standardizedFileURL.path
        for root in compiledCacheRoots where !root.standardizedFileURL.path.hasPrefix(supportPath + "/") {
            scanFiles(at: root) { _, bytes in result.clearableFiles += bytes }
        }
        return result
    }

    func clearFileCaches(workspaceURLs: [URL]) throws {
        let workspaceRoot = appSupportRoot.appendingPathComponent("workspaces", isDirectory: true)
        let storedWorkspaces = (try? fileManager.contentsOfDirectory(
            at: workspaceRoot, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let briefingRoots = Set([appSupportRoot] + workspaceURLs + storedWorkspaces).map {
            $0.appendingPathComponent("briefings", isDirectory: true)
        }
        for url in briefingRoots + [cacheRoot] + compiledCacheRoots where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        // ACPIconCache keeps its directory URL for the process lifetime.
        try fileManager.createDirectory(
            at: cacheRoot.appendingPathComponent("acp-icons", isDirectory: true),
            withIntermediateDirectories: true
        )
        URLCache.shared.removeAllCachedResponses()
    }

    private func scanFiles(at root: URL, visit: (URL, Int64) -> Void) {
        guard let files = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return }
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            visit(url, Int64(values.fileSize ?? 0))
        }
    }
}
