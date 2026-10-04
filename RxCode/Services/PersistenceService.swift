import Foundation
import RxCodeCore
import os

protocol AppStatePersistenceService: Actor {
    func saveProjects(_ projects: [Project]) throws
    func loadProjects() -> [Project]

    func saveSession(_ session: ChatSession, persistTitle: Bool) async throws
    func migrateSessionsToGlobalStorage()
    func loadLegacySessions(for projectId: UUID) -> [ChatSession.Summary]
    func loadAllLegacySessionSummaries() -> [ChatSession.Summary]
    func deleteSession(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?) async throws
    func loadFullSession(summary: ChatSession.Summary, cwd: String) async -> ChatSession?
    nonisolated func loadSessionSync(sessionId: String) -> ChatSession?

    func saveRunProfiles(_ profiles: [RunProfile], projectId: UUID) throws
    func loadRunProfiles(projectId: UUID) -> [RunProfile]

    func saveHookProfiles(_ profiles: [HookProfile], projectId: UUID) throws
    func loadHookProfiles(projectId: UUID) -> [HookProfile]

    func saveTaskBoard(_ board: TaskBoard, projectId: UUID) throws
    func loadTaskBoard(projectId: UUID) -> TaskBoard
    func deleteTaskBoard(projectId: UUID) throws

    func saveACPClients(_ clients: [ACPClientSpec]) throws
    func loadACPClients() -> [ACPClientSpec]
    nonisolated func acpRegistrySnapshotURL() -> URL

    func saveScheduledTasks(_ tasks: [ScheduledTask]) throws
    func loadScheduledTasks() -> [ScheduledTask]

    func saveScheduledTaskRuns(_ runs: [ScheduledTaskRun]) throws
    func loadScheduledTaskRuns() -> [ScheduledTaskRun]
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
            try encode(session, to: sessionURL(sessionId: session.id))
            // Only discard the old copy after the atomic global write succeeds.
            for url in legacySessionFiles() where url.deletingPathExtension().lastPathComponent == session.id {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Session identity is global. Project IDs remain metadata for agent context.
    nonisolated func sessionURL(sessionId: String) -> URL {
        baseURL.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionId).json")
    }

    /// Moves old project-scoped transcripts without re-encoding their contents.
    /// Existing global files win; failed or conflicting moves retain the source.
    /// Safe to repeat after an interrupted migration.
    func migrateSessionsToGlobalStorage() {
        for source in legacySessionFiles() {
            guard let session = decodeSessionFile(ChatSession.self, from: source),
                  source.deletingPathExtension().lastPathComponent == session.id else { continue }
            let destination = sessionURL(sessionId: session.id)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                logger.error("Session migration failed for \(session.id, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private nonisolated func legacySessionFiles() -> [URL] {
        let fm = FileManager.default
        let root = baseURL.appendingPathComponent("sessions", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return entries.sorted { $0.path < $1.path }.flatMap { directory -> [URL] in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            return ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.path < $1.path }
        }
    }

    /// Compatibility filter for project surfaces; all transcripts share one store.
    func loadLegacySessions(for projectId: UUID) -> [ChatSession.Summary] {
        loadAllLegacySessionSummaries().filter { $0.projectId == projectId }
    }

    func loadAllLegacySessionSummaries() -> [ChatSession.Summary] {
        migrateSessionsToGlobalStorage()
        let root = baseURL.appendingPathComponent("sessions", isDirectory: true)
        let globalFiles = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []).filter { $0.pathExtension == "json" }
        var seen = Set<String>()
        // Failed migrations remain readable. A canonical global copy takes priority.
        return (globalFiles + legacySessionFiles()).compactMap { url in
            guard var summary = decodeSessionFile(ChatSession.Summary.self, from: url),
                  seen.insert(summary.id).inserted else { return nil }
            if summary.origin == .cliBacked { summary.origin = .legacyRxCode }
            return summary
        }.sorted { $0.updatedAt > $1.updatedAt }
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
            try removeSessionFiles(sessionId: sessionId)
        case .legacyRxCode, .codexAppServer, .acpAgent:
            try removeSessionFiles(sessionId: sessionId)
        }
    }

    private func removeSessionFiles(sessionId: String) throws {
        let fm = FileManager.default
        let urls = legacySessionFiles().filter { $0.deletingPathExtension().lastPathComponent == sessionId }
            + [sessionURL(sessionId: sessionId)]
        // Remove old copies first so a failure cannot resurrect a deleted global file.
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Loads the full message history. Routes by `origin`:
    /// - `.cliBacked` → CLI jsonl
    /// - `.legacyRxCode` / `.codexAppServer` / `.acpAgent` → RxCode's global json
    func loadFullSession(summary: ChatSession.Summary, cwd: String) async -> ChatSession? {
        switch summary.origin {
        case .cliBacked:
            return await cliStore.loadFullSession(
                sid: summary.id,
                cwd: cwd,
                projectId: summary.projectId
            )
        case .legacyRxCode, .codexAppServer, .acpAgent:
            return loadSessionSync(sessionId: summary.id)
        }
    }

    /// Compatibility accessor; new transcript locations never depend on project ID.
    nonisolated func legacySessionURL(projectId: UUID, sessionId: String) -> URL {
        sessionURL(sessionId: sessionId)
    }

    nonisolated func loadLegacySessionSync(projectId: UUID, sessionId: String) -> ChatSession? {
        loadSessionSync(sessionId: sessionId)
    }

    nonisolated func loadSessionSync(sessionId: String) -> ChatSession? {
        func read(_ url: URL) -> ChatSession? {
            guard let session = decodeSessionFile(ChatSession.self, from: url),
                  session.id == sessionId else { return nil }
            return session
        }
        if let session = read(sessionURL(sessionId: sessionId)) { return session }
        for url in legacySessionFiles() where url.deletingPathExtension().lastPathComponent == sessionId {
            if let session = read(url) { return session }
        }
        return nil
    }

    /// Session migration and fallback reads must never rename or discard an
    /// unreadable transcript; a newer app version may be able to recover it.
    private nonisolated func decodeSessionFile<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
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

    // MARK: - Task Board

    func saveTaskBoard(_ board: TaskBoard, projectId: UUID) throws {
        let url = taskBoardURL(projectId: projectId)
        try encode(board, to: url)
    }

    func loadTaskBoard(projectId: UUID) -> TaskBoard {
        let url = taskBoardURL(projectId: projectId)
        return decode(TaskBoard.self, from: url) ?? TaskBoard()
    }

    /// Removes a deleted project's board. Missing file is not an error.
    func deleteTaskBoard(projectId: UUID) throws {
        let url = taskBoardURL(projectId: projectId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func taskBoardURL(projectId: UUID) -> URL {
        baseURL
            .appendingPathComponent("task_board")
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

    // MARK: - Scheduled Tasks

    func saveScheduledTasks(_ tasks: [ScheduledTask]) throws {
        let url = baseURL.appendingPathComponent("scheduled_tasks.json")
        try encode(tasks, to: url)
    }

    func loadScheduledTasks() -> [ScheduledTask] {
        let url = baseURL.appendingPathComponent("scheduled_tasks.json")
        return decode([ScheduledTask].self, from: url) ?? []
    }

    func saveScheduledTaskRuns(_ runs: [ScheduledTaskRun]) throws {
        let url = baseURL.appendingPathComponent("scheduled_task_runs.json")
        try encode(runs, to: url)
    }

    func loadScheduledTaskRuns() -> [ScheduledTaskRun] {
        let url = baseURL.appendingPathComponent("scheduled_task_runs.json")
        return decode([ScheduledTaskRun].self, from: url) ?? []
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
