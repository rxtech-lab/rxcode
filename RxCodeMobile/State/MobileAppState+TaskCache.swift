import Foundation
import RxCodeCore
import RxCodeSync

/// The task projects and boards last seen for one source (a paired Mac or a
/// cloud account), so the Tasks tab can show them at launch before the
/// first fetch replies.
struct MobileTaskCache: Codable, Sendable {
    var projects: [Project]
    var boards: [MobileTaskBoardSnapshot]

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskCache", isDirectory: true)
    }

    static func desktopURL(_ pubkeyHex: String) -> URL {
        directory.appendingPathComponent("desktop-\(pubkeyHex).json")
    }

    static func cloudURL(_ accountID: String) -> URL {
        let safe = accountID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? accountID
        return directory.appendingPathComponent("cloud-\(safe).json")
    }

    static func load(from url: URL) -> MobileTaskCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MobileTaskCache.self, from: data)
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes cache files whose source is gone: Macs no longer paired, or
    /// every cloud account after sign-out.
    static func prune(keepingDesktops pubkeys: Set<String>, keepCloud: Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let kept = Set(pubkeys.map { desktopURL($0).lastPathComponent })
        for file in files {
            let name = file.lastPathComponent
            let isStale = name.hasPrefix("cloud-") ? !keepCloud : !kept.contains(name)
            if isStale { try? FileManager.default.removeItem(at: file) }
        }
    }
}

extension MobileAppState {
    static let taskCacheSaveDelay: Duration = .seconds(1)

    // MARK: - Restore

    /// Shows the active Mac's cached boards until its first snapshot arrives.
    func restoreDesktopTaskCache() {
        guard !pairedDesktopPubkey.isEmpty, !hasReceivedInitialSnapshot, taskBoardsByProject.isEmpty,
              let cache = MobileTaskCache.load(from: MobileTaskCache.desktopURL(pairedDesktopPubkey))
        else {
            cachedDesktopTaskProjects = []
            return
        }
        cachedDesktopTaskProjects = cache.projects
        taskBoardsByProject = Dictionary(cache.boards.map { ($0.projectID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Shows the signed-in account's cached cloud boards before the first
    /// cloud fetch. Restoring the boards' sync links keeps task IDs stable
    /// once the fetch replaces them.
    func restoreCloudTaskCacheIfNeeded() {
        guard usesCloudTasks, cloudTaskProjects.isEmpty, cloudTaskBoards.isEmpty,
              let accountID = taskCloud?.accountID,
              let cache = MobileTaskCache.load(from: MobileTaskCache.cloudURL(accountID))
        else { return }
        cloudTaskProjects = cache.projects
        cloudTaskBoards = Dictionary(cache.boards.map { ($0.projectID, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Save

    /// Writes the current boards to disk shortly after the last change.
    func scheduleTaskCacheSave() {
        taskCacheSaveTask?.cancel()
        taskCacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.taskCacheSaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.taskCacheSaveTask = nil
            self.saveTaskCache()
        }
    }

    private func saveTaskCache() {
        var writes: [(MobileTaskCache, URL)] = []
        // Only a Mac's own project list is authoritative; the cached one is
        // just a stand-in until its snapshot arrives.
        if hasReceivedInitialSnapshot, !pairedDesktopPubkey.isEmpty, !projects.isEmpty {
            writes.append((Self.taskCache(projects: projects, boards: taskBoardsByProject),
                           MobileTaskCache.desktopURL(pairedDesktopPubkey)))
        }
        if let accountID = taskCloud?.accountID, taskCloud?.isSignedIn == true, !cloudTaskProjects.isEmpty {
            writes.append((Self.taskCache(projects: cloudTaskProjects, boards: cloudTaskBoards),
                           MobileTaskCache.cloudURL(accountID)))
        }
        guard !writes.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (cache, url) in writes { try? cache.save(to: url) }
        }
    }

    private static func taskCache(projects: [Project], boards: [UUID: MobileTaskBoardSnapshot]) -> MobileTaskCache {
        MobileTaskCache(projects: projects, boards: projects.compactMap { boards[$0.id] })
    }

    /// Drops caches for unpaired Macs, and cloud caches once signed out.
    func pruneTaskCache(keepCloud: Bool = true) {
        if !keepCloud { taskCacheSaveTask?.cancel() }
        let pubkeys = Set(pairedDesktops.map(\.pubkeyHex))
        Task.detached(priority: .utility) {
            MobileTaskCache.prune(keepingDesktops: pubkeys, keepCloud: keepCloud)
        }
    }
}
