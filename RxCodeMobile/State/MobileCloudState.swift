import Foundation
import Observation
import UIKit
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
    var pendingNotification: FlowcyPushDestination?
    private var generation = UUID()
    private(set) var isSigningOut = false
    @ObservationIgnored lazy var push = FlowcyPushRegistration(deviceName: UIDevice.current.name) { method, body in
        _ = try await FlowcyAPI(notifySessionExpiry: false).read("notifications/devices", method: method, body: body)
    }
    @ObservationIgnored private lazy var service = ProjectCloudService(rxAuth: auth)

    var accountID: String? { auth.user?.id }

    var isSignedIn: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-cloud") { return true }
        #endif
        return auth.isAuthenticated
    }

    init(service: ProjectCloudService? = nil) {
        if let service {
            self.service = service
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-cloud") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CloudUITestProtocol.self]
            self.service = ProjectCloudService(session: URLSession(configuration: config), baseURL: URL(string: "https://cloud-ui.test")!) { _ in "ui-test" }
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

    func signOut(requiresPushRemoval: Bool = true) async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do { try await push.disconnect(accountID: accountID) }
        catch {
            if requiresPushRemoval {
                self.error = "Could not disconnect notifications. Retry signing out while connected."
                return
            }
        }
        push.sessionEnded()
        generation = UUID()
        projects = []
        boards = [:]
        devices = []
        error = nil
        deviceError = nil
        await auth.signOut()
    }

    func refresh() async {
        Task { [weak self] in
            guard let self, !isSigningOut, isSignedIn else { return }
            await push.synchronize(accountID: accountID)
        }
        let current = generation
        do {
            try await refreshProjects()
        } catch {
            guard current == generation, !Self.isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
        do {
            let result = try await service.listDevices()
            guard current == generation, isSignedIn else { return }
            devices = result
            deviceError = nil
        } catch {
            guard current == generation, !Self.isCancellation(error) else { return }
            deviceError = error.localizedDescription
        }
    }

    /// Board loading needs this request's result, not a shared error from another refresh.
    func refreshProjects() async throws {
        let current = generation
        let result = try await service.listProjects()
        try Task.checkCancellation()
        try checkSession(current)
        projects = result
        boards = boards.filter { id, _ in result.contains { $0.id == id } }
        error = nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func loadBoard(_ projectID: String) async throws {
        let current = generation
        let board = try await service.board(projectId: projectID)
        try checkSession(current)
        boards[projectID] = board
    }

    func savedViews(_ projectID: String) async throws -> CloudSavedViews? {
        let current = generation
        let result = try await service.savedViews(projectId: projectID)
        try checkSession(current)
        return result
    }

    func saveViews(_ settings: CloudSavedViews, projectID: String) async throws -> CloudSavedViews {
        let current = generation
        let result = try await service.saveViews(settings, projectId: projectID)
        try checkSession(current)
        return result
    }

    func createProject(name: String) async throws {
        let current = generation
        let project = try await service.createProject(name: name)
        try checkSession(current)
        projects.append(project)
    }

    func generateDraft(projectID: String, kind: ProjectCloudService.DraftKind, prompt: String) async throws -> ProjectCloudService.ItemDraft {
        let current = generation
        guard isSignedIn else { throw CancellationError() }
        let draft = try await service.generateDraft(projectId: projectID, kind: kind, prompt: prompt)
        try Task.checkCancellation()
        try checkSession(current)
        return draft
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
