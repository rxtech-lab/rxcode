import Foundation
import RxCodeCore
@testable import RxCode

/// Shared by the app-level test target (also used by `TaskBoardHookTests`).
actor MockAppStatePersistence: AppStatePersistenceService {
    private var projectSnapshots: [[Project]] = []
    private var sessionSaves: [(session: ChatSession, persistTitle: Bool)] = []
    private var deletedSessions: [(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?)] = []
    private var runProfiles: [UUID: [RunProfile]] = [:]
    private var hookProfiles: [UUID: [HookProfile]] = [:]
    private var taskBoards: [UUID: TaskBoard] = [:]
    private var acpClients: [ACPClientSpec] = []
    private var scheduledTasks: [ScheduledTask] = []
    private var fullSessions: [String: ChatSession] = [:]
    private var legacySessions: [String: ChatSession] = [:]

    func savedProjectsSnapshots() -> [[Project]] {
        projectSnapshots
    }

    func savedSessions() -> [(session: ChatSession, persistTitle: Bool)] {
        sessionSaves
    }

    func deletedSessionRecords() -> [(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?)] {
        deletedSessions
    }

    func stubFullSession(_ session: ChatSession) {
        fullSessions[session.id] = session
    }

    func stubLegacySession(_ session: ChatSession) {
        legacySessions[session.id] = session
    }

    func saveProjects(_ projects: [Project]) throws {
        projectSnapshots.append(projects)
    }

    func loadProjects() -> [Project] {
        projectSnapshots.last ?? []
    }

    func saveSession(_ session: ChatSession, persistTitle: Bool) async throws {
        sessionSaves.append((session, persistTitle))
    }

    func migrateSessionsToGlobalStorage() {}

    func loadLegacySessions(for projectId: UUID) -> [ChatSession.Summary] {
        legacySessions.values
            .filter { $0.projectId == projectId }
            .map(\.summary)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadAllLegacySessionSummaries() -> [ChatSession.Summary] {
        legacySessions.values.map(\.summary).sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteSession(projectId: UUID, sessionId: String, origin: SessionOrigin, cwd: String?) async throws {
        deletedSessions.append((projectId, sessionId, origin, cwd))
    }

    func loadFullSession(summary: ChatSession.Summary, cwd: String) async -> ChatSession? {
        fullSessions[summary.id]
    }

    nonisolated func legacySessionURL(projectId: UUID, sessionId: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(projectId.uuidString)/\(sessionId).json")
    }

    nonisolated func loadSessionSync(sessionId: String) -> ChatSession? {
        nil
    }

    func saveRunProfiles(_ profiles: [RunProfile], projectId: UUID) throws {
        runProfiles[projectId] = profiles
    }

    func loadRunProfiles(projectId: UUID) -> [RunProfile] {
        runProfiles[projectId] ?? []
    }

    func saveHookProfiles(_ profiles: [HookProfile], projectId: UUID) throws {
        hookProfiles[projectId] = profiles
    }

    func loadHookProfiles(projectId: UUID) -> [HookProfile] {
        hookProfiles[projectId] ?? []
    }

    func saveTaskBoard(_ board: TaskBoard, projectId: UUID) throws {
        taskBoards[projectId] = board
    }

    func loadTaskBoard(projectId: UUID) -> TaskBoard {
        taskBoards[projectId] ?? TaskBoard()
    }

    func deleteTaskBoard(projectId: UUID) throws {
        taskBoards.removeValue(forKey: projectId)
    }

    func saveACPClients(_ clients: [ACPClientSpec]) throws {
        acpClients = clients
    }

    func loadACPClients() -> [ACPClientSpec] {
        acpClients
    }

    nonisolated func acpRegistrySnapshotURL() -> URL {
        URL(fileURLWithPath: "/tmp/acp_registry.json")
    }

    func saveScheduledTasks(_ tasks: [ScheduledTask]) throws {
        scheduledTasks = tasks
    }

    func loadScheduledTasks() -> [ScheduledTask] {
        scheduledTasks
    }
}
