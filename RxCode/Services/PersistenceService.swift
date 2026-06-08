import Foundation
import RxCodeCore
import os

protocol AppStatePersistenceService: Actor {
    func saveProjects(_ projects: [Project]) throws
    func loadProjects() -> [Project]

    func saveSession(_ session: ChatSession, persistTitle: Bool) async throws
    func loadLegacySessions(for projectId: UUID) -> [ChatSession.Summary]
    func loadAllLegacySessionSummaries() -> [ChatSession.Summary]
    func deleteSession(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?) async throws
    func loadFullSession(summary: ChatSession.Summary, cwd: String) async -> ChatSession?
    nonisolated func legacySessionURL(projectId: UUID, sessionId: String) -> URL
    nonisolated func loadLegacySessionSync(projectId: UUID, sessionId: String) -> ChatSession?

    func saveRunProfiles(_ profiles: [RunProfile], projectId: UUID) throws
    func loadRunProfiles(projectId: UUID) -> [RunProfile]

    func saveHookProfiles(_ profiles: [HookProfile], projectId: UUID) throws
    func loadHookProfiles(projectId: UUID) -> [HookProfile]

    func saveACPClients(_ clients: [ACPClientSpec]) throws
    func loadACPClients() -> [ACPClientSpec]
    nonisolated func acpRegistrySnapshotURL() -> URL
}

extension AppStatePersistenceService {
    func saveSession(_ session: ChatSession) async throws {
        try await saveSession(session, persistTitle: false)
    }
}

actor PersistenceService: AppStatePersistenceService {

    private let baseURL: URL
    private let metaStore: SessionMetaStore
    private let cliStore: CLISessionStore
    private let logger = Logger(subsystem: "com.claudework", category: "PersistenceService")

    init(metaStore: SessionMetaStore, cliStore: CLISessionStore, baseURL: URL = AppSupport.bundleScopedURL) {
        self.baseURL = baseURL
        self.metaStore = metaStore
        self.cliStore = cliStore
    }

    // MARK: - Projects

    func saveProjects(_ projects: [Project]) throws {
        let url = baseURL.appendingPathComponent("projects.json")
        try encode(projects, to: url)
    }

    func loadProjects() -> [Project] {
        let url = baseURL.appendingPathComponent("projects.json")
        return decode([Project].self, from: url) ?? []
    }

    // MARK: - Sessions

    func saveSession(_ session: ChatSession, persistTitle: Bool = false) async throws {
        switch session.origin {
        case .cliBacked:
            // CLI owns the message log (jsonl). We only persist the RxCode-only
            // sidecar — title/pin/model/effort/permissionMode.
            //
            // Title rule: the sidecar holds *user-renamed* titles only. Auto
            // saves leave it untouched so the listing falls back to the jsonl
            // first-message sniff, matching what the CLI's --resume shows.
            let titleToWrite: String?
            if persistTitle {
                titleToWrite = session.title
            } else {
                titleToWrite = await metaStore.load(sessionId: session.id).title
            }
            await metaStore.save(
                sessionId: session.id,
                meta: SessionMetaStore.Meta(
                    title: titleToWrite,
                    isPinned: session.isPinned,
                    agentProvider: session.agentProvider,
                    model: session.model,
                    effort: session.effort,
                    permissionMode: session.permissionMode,
                    updatedAt: session.updatedAt,
                    worktreePath: session.worktreePath,
                    worktreeBranch: session.worktreeBranch
                )
            )

        case .legacyRxCode, .codexAppServer, .acpAgent:
            let dir = baseURL
                .appendingPathComponent("sessions")
                .appendingPathComponent(session.projectId.uuidString)
            try ensureDirectory(dir)
            let url = dir.appendingPathComponent("\(session.id).json")
            try encode(session, to: url)
        }
    }

    /// Lightweight load of legacy session list for a project. CLI-backed
    /// summaries are loaded separately by `CLISessionStore.loadSummaries`.
    func loadLegacySessions(for projectId: UUID) -> [ChatSession.Summary] {
        let dir = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(projectId.uuidString)

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSession.Summary? in
                guard var summary = decode(ChatSession.Summary.self, from: url) else { return nil }
                // Files saved before this change may decode as `.legacyRxCode`
                // already (default), but be defensive.
                if summary.origin != .legacyRxCode && summary.origin != .codexAppServer && summary.origin != .acpAgent {
                    summary = ChatSession.Summary(
                        id: summary.id, projectId: summary.projectId, title: summary.title,
                        createdAt: summary.createdAt, updatedAt: summary.updatedAt,
                        isPinned: summary.isPinned, agentProvider: summary.agentProvider,
                        model: summary.model,
                        effort: summary.effort, permissionMode: summary.permissionMode,
                        origin: .legacyRxCode,
                        worktreePath: summary.worktreePath,
                        worktreeBranch: summary.worktreeBranch,
                        isArchived: summary.isArchived,
                        archivedAt: summary.archivedAt
                    )
                }
                return summary
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Lightweight load of legacy session summaries across all projects.
    func loadAllLegacySessionSummaries() -> [ChatSession.Summary] {
        let sessionsDir = baseURL.appendingPathComponent("sessions")
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        var summaries: [ChatSession.Summary] = []
        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "json" {
                if let summary = decode(ChatSession.Summary.self, from: file) {
                    summaries.append(summary)
                }
            }
        }

        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteSession(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?) async throws {
        switch origin {
        case .cliBacked:
            await metaStore.delete(sessionId: sessionId)
            if let cwd {
                await cliStore.deleteSession(sid: sessionId, cwd: cwd)
            } else {
                logger.warning("Skipping CLI jsonl delete for \(sessionId, privacy: .public): cwd unavailable")
            }
            // Pre-cli-sync builds wrote a RxCode-side json with the same sid. If
            // it survives, the merge in AppState falls back to it after the
            // jsonl is gone and the entry resurrects on the next reload.
            try removeLegacySessionFile(projectId: projectId, sessionId: sessionId)
        case .legacyRxCode, .codexAppServer, .acpAgent:
            try removeLegacySessionFile(projectId: projectId, sessionId: sessionId)
        }
    }

    private func removeLegacySessionFile(projectId: UUID, sessionId: String) throws {
        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("\(sessionId).json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
        logger.debug("Deleted legacy session \(sessionId, privacy: .public)")
    }

    /// Loads the full message history. Routes by `origin`:
    /// - `.cliBacked` → CLI jsonl
    /// - `.legacyRxCode` / `.codexAppServer` / `.acpAgent` → RxCode's per-project json
    func loadFullSession(summary: ChatSession.Summary, cwd: String) async -> ChatSession? {
        switch summary.origin {
        case .cliBacked:
            return await cliStore.loadFullSession(
                sid: summary.id,
                cwd: cwd,
                projectId: summary.projectId
            )
        case .legacyRxCode, .codexAppServer, .acpAgent:
            return loadLegacySessionSync(projectId: summary.projectId, sessionId: summary.id)
        }
    }

    /// Synchronous load for legacy json sessions. Kept available for the few
    /// MainActor sites that still call it directly.
    nonisolated func legacySessionURL(projectId: UUID, sessionId: String) -> URL {
        baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("\(sessionId).json")
    }

    nonisolated func loadLegacySessionSync(projectId: UUID, sessionId: String) -> ChatSession? {
        let url = legacySessionURL(projectId: projectId, sessionId: sessionId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatSession.self, from: data)
    }

    // MARK: - Run Profiles

    func saveRunProfiles(_ profiles: [RunProfile], projectId: UUID) throws {
        let url = runProfilesURL(projectId: projectId)
        try encode(profiles, to: url)
    }

    func loadRunProfiles(projectId: UUID) -> [RunProfile] {
        let url = runProfilesURL(projectId: projectId)
        return decode([RunProfile].self, from: url) ?? []
    }

    private func runProfilesURL(projectId: UUID) -> URL {
        baseURL
            .appendingPathComponent("run_profiles")
            .appendingPathComponent("\(projectId.uuidString).json")
    }

    // MARK: - Hook Profiles

    func saveHookProfiles(_ profiles: [HookProfile], projectId: UUID) throws {
        let url = hookProfilesURL(projectId: projectId)
        try encode(profiles, to: url)
    }

    func loadHookProfiles(projectId: UUID) -> [HookProfile] {
        let url = hookProfilesURL(projectId: projectId)
        return decode([HookProfile].self, from: url) ?? []
    }

    private func hookProfilesURL(projectId: UUID) -> URL {
        baseURL
            .appendingPathComponent("hooks")
            .appendingPathComponent("\(projectId.uuidString).json")
    }

    // MARK: - ACP Clients

    func saveACPClients(_ clients: [ACPClientSpec]) throws {
        let url = baseURL.appendingPathComponent("acp_clients.json")
        try encode(clients, to: url)
    }

    func loadACPClients() -> [ACPClientSpec] {
        let url = baseURL.appendingPathComponent("acp_clients.json")
        return decode([ACPClientSpec].self, from: url) ?? []
    }

    /// Returns the on-disk URL for the cached ACP registry snapshot. The
    /// `ACPRegistryService` reads/writes this file directly.
    nonisolated func acpRegistrySnapshotURL() -> URL {
        baseURL.appendingPathComponent("acp_registry.json")
    }

    // MARK: - Private Helpers

    private func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)

        logger.debug("Saved \(url.lastPathComponent, privacy: .public)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            logger.error(
                "Failed to decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // Move corrupted file to a backup to preserve data
            let backupURL = url.deletingPathExtension()
                .appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: url, to: backupURL)
            logger.warning("Moved corrupted file to \(backupURL.lastPathComponent, privacy: .public)")
            return nil
        }
    }
}
