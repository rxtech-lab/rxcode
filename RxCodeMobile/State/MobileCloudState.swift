import Foundation
import Observation
import RxCodeCore
import RxAuthSwift

/// Direct account access to Autopilot, independent of the paired desktop transport.
@MainActor @Observable
final class MobileCloudState {
    let auth = RxAuthService.shared
    private(set) var projects: [CloudProject] = []
    private(set) var boards: [String: CloudRemoteBoard] = [:]
    private(set) var devices: [CloudDevice] = []
    private(set) var isRestoring = true
    private(set) var isSigningIn = false
    var error: String?
    var deviceError: String?
    private var generation = UUID()
    @ObservationIgnored private lazy var service = ProjectCloudService(rxAuth: auth)

    var accountID: String? { auth.user?.id }

    var isSignedIn: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-cloud") { return true }
        #endif
        return auth.isAuthenticated
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-cloud") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CloudUITestProtocol.self]
            service = ProjectCloudService(session: URLSession(configuration: config), baseURL: URL(string: "https://cloud-ui.test")!) { _ in "ui-test" }
            isRestoring = false
        }
        #endif
    }

    func restore() async {
        guard isRestoring else { return }
        await auth.restore()
        isRestoring = false
        if isSignedIn { await refresh() }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func signOut() async {
        generation = UUID()
        projects = []
        boards = [:]
        devices = []
        error = nil
        deviceError = nil
        await auth.signOut()
    }

    func refresh() async {
        let current = generation
        do {
            let result = try await service.listProjects()
            guard current == generation, isSignedIn else { return }
            projects = result
            boards = boards.filter { id, _ in result.contains { $0.id == id } }
            error = nil
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
        }
        do {
            let result = try await service.listDevices()
            guard current == generation, isSignedIn else { return }
            devices = result
            deviceError = nil
        } catch {
            guard current == generation else { return }
            deviceError = error.localizedDescription
        }
    }

    func loadBoard(_ projectID: String) async throws {
        let current = generation
        let board = try await service.board(projectId: projectID)
        try checkSession(current)
        boards[projectID] = board
    }

    func createProject(name: String) async throws {
        let current = generation
        let project = try await service.createProject(name: name)
        try checkSession(current)
        projects.append(project)
    }

    @discardableResult
    func saveTask(_ fields: CloudTaskFields, id: String?, projectID: String) async throws -> CloudRemoteTask {
        let current = generation
        let task: CloudRemoteTask
        if let id {
            task = try await service.updateTask(projectId: projectID, taskId: id, fields: fields)
        } else {
            task = try await service.createTask(projectId: projectID, fields: fields)
        }
        try checkSession(current)
        var board = boards[projectID] ?? CloudRemoteBoard()
        board.tasks.removeAll { $0.id == task.id }
        board.tasks.append(task)
        boards[projectID] = board
        return task
    }

    @discardableResult
    func saveStory(_ fields: CloudStoryFields, id: String?, projectID: String) async throws -> CloudRemoteStory {
        let current = generation
        let story: CloudRemoteStory
        if let id {
            story = try await service.updateStory(projectId: projectID, storyId: id, fields: fields)
        } else {
            story = try await service.createStory(projectId: projectID, fields: fields)
        }
        try checkSession(current)
        var board = boards[projectID] ?? CloudRemoteBoard()
        board.stories.removeAll { $0.id == story.id }
        board.stories.append(story)
        boards[projectID] = board
        return story
    }

    func deleteTask(_ id: String, projectID: String) async throws {
        let current = generation
        try await service.deleteTask(projectId: projectID, taskId: id)
        try checkSession(current)
        boards[projectID]?.tasks.removeAll { $0.id == id }
        // Reload to apply the server's parent-link cleanup.
        try await loadBoard(projectID)
    }

    func deleteStory(_ id: String, projectID: String) async throws {
        let current = generation
        try await service.deleteStory(projectId: projectID, storyId: id)
        try checkSession(current)
        boards[projectID]?.stories.removeAll { $0.id == id }
        try await loadBoard(projectID)
    }

    private func checkSession(_ expected: UUID) throws {
        guard expected == generation, isSignedIn else { throw CancellationError() }
    }
}
