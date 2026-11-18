import Foundation
import CryptoKit
import RxAuthSwift
import RxCodeCore
import RxCodeSync
import os

/// Talks to Autopilot's project board API (`/api/v1/docs/repositories`) with
/// the rxauth bearer, so cloud projects and their stories and tasks sync to
/// every device signed in to the same account.
@MainActor
final class ProjectCloudService {

    @TaskLocal static var syncAccount: String?
    private let tokenProvider: (Bool) async -> String?
    private let configuredBaseURL: URL?
    private let logger = Logger(subsystem: "com.claudework", category: "ProjectCloudService")
    private let session: URLSession

    private let accountID: () -> String?
    private struct Scope: Hashable {
        let account: String
        let project: String
    }
    private var boards: [Scope: CloudRemoteBoard] = [:]
    private let snapshots = CloudSnapshotCache()
    private var views: [Scope: CloudSavedViews] = [:]

    private func scope(_ project: String) -> Scope? {
        accountID().map { Scope(account: $0, project: project) }
    }

    convenience init(rxAuth: RxAuthService) {
        self.init(session: .shared, baseURL: nil, accountID: { rxAuth.user?.id }) { forceRefresh in
            await rxAuth.accessToken(forceRefresh: forceRefresh)
        }
    }

    init(session: URLSession, baseURL: URL?, accountID: @escaping () -> String? = { nil }, tokenProvider: @escaping (Bool) async -> String?) {
        self.accountID = accountID
        self.session = session
        self.configuredBaseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    var baseURL: URL {
        if let configuredBaseURL { return configuredBaseURL }
        let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String
        if let override, !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://www.flowcy.dev")!
    }

    private var projectsURL: URL { baseURL.appendingPathComponent("/api/v1/docs/repositories") }

    private func projectURL(_ id: String) -> URL { projectsURL.appendingPathComponent(id) }

    func saveTaskActivity(projectId: String, taskId: String, envelope: EncryptedTaskActivity) async throws {
        let _: EncryptedTaskActivity = try await request("PUT",
            url: projectURL(projectId).appendingPathComponent("tasks/\(taskId)/activity"), body: envelope)
    }

    private struct ActivityScope: Hashable {
        let board: Scope
        let recipient: String
    }

    nonisolated private struct StoredActivity: Codable, Sendable {
        let checkpoint: String
        let items: [CloudTaskActivityRecord]
    }

    private struct EnvelopeID: Hashable {
        let task: String
        let sender: String
    }

    private var activities: [ActivityScope: (checkpoint: String, records: [EnvelopeID: CloudTaskActivityRecord])] = [:]

    func taskActivity(projectId: String, recipient: String) async throws -> [CloudTaskActivityRecord] {
        let key = scope(projectId).map { ActivityScope(board: $0, recipient: recipient) }
        let cached = key.flatMap { activities[$0] }
        var since = cached?.checkpoint
        var records = cached?.records ?? [:]
        let file = key.map { [baseURL.absoluteString, $0.board.account, projectId, "activity", recipient] }
        if cached == nil, let file, let saved = await snapshots.load(StoredActivity.self, key: file) {
            since = saved.checkpoint
            for item in saved.items {
                records[EnvelopeID(task: item.taskId, sender: item.envelope.sender)] = item
            }
        }
        let original = since
        var cursor: String?
        var target: String?
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            guard scope(projectId) == key?.board else { throw CancellationError() }
            var url = projectURL(projectId).appendingPathComponent("activity")
            url.append(queryItems: [URLQueryItem(name: "recipient", value: recipient)])
            if let since { url.append(queryItems: [URLQueryItem(name: "since", value: since)]) }
            if let cursor { url.append(queryItems: [URLQueryItem(name: "cursor", value: cursor)]) }
            let page: CloudTaskActivityPage
            do {
                page = try await request("GET", url: url)
            } catch AutopilotService.ServiceError.apiError(410, _) where since != nil {
                since = nil
                records = [:]
                cursor = nil
                target = nil
                seen = []
                continue
            }
            guard scope(projectId) == key?.board else { throw CancellationError() }
            if cursor != nil && page.checkpoint != target { throw URLError(.cannotParseResponse) }
            if since != nil && page.checkpoint == nil {
                guard cursor == nil, page.deletedTaskIds == nil else { throw URLError(.cannotParseResponse) }
                records = [:]
                since = nil
            }
            if since != nil && page.deletedTaskIds == nil { throw URLError(.cannotParseResponse) }
            target = page.checkpoint
            if let deleted = page.deletedTaskIds, !deleted.isEmpty {
                let ids = Set(deleted)
                records = records.filter { !ids.contains($0.key.task) }
            }
            for record in page.items {
                records[EnvelopeID(task: record.taskId, sender: record.envelope.sender)] = record
            }
            guard let next = page.nextCursor else {
                if let key { activities[key] = target.map { ($0, records) } }
                if let file, original != target {
                    await snapshots.store(target.map { StoredActivity(checkpoint: $0, items: Array(records.values)) }, key: file)
                }
                guard scope(projectId) == key?.board else { throw CancellationError() }
                return records.values.sorted { ($0.taskId, $0.envelope.sender) < ($1.taskId, $1.envelope.sender) }
            }
            guard seen.insert(next).inserted else { throw URLError(.cannotParseResponse) }
            cursor = next
        }
    }

    // MARK: - Projects

    /// Every Autopilot project the signed-in user can access, across pages.
    func listProjects() async throws -> [CloudProject] {
        var all: [CloudProject] = []
        var cursor: String?
        repeat {
            var components = URLComponents(url: projectsURL, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "pageSize", value: "100"), URLQueryItem(name: "boardOnly", value: "true")]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components?.queryItems = items
            guard let url = components?.url else { throw AutopilotService.ServiceError.invalidResponse }
            let page: CloudProjectListResponse = try await request("GET", url: url)
            all.append(contentsOf: page.items)
            cursor = page.pagination?.hasMore == true ? page.pagination?.nextCursor : nil
        } while cursor != nil
        return all
    }

    private struct CreateStandaloneProject: Encodable {
        let type = "standalone"
        let name: String
        let description: String?
    }

    func createProject(name: String, description: String? = nil) async throws -> CloudProject {
        try await request("POST", url: projectsURL, body: CreateStandaloneProject(name: name, description: description))
    }

    // MARK: - Laptops

    func listDevices() async throws -> [CloudDevice] {
        try await request("GET", url: baseURL.appendingPathComponent("api/v1/devices"))
    }

    func registerDevice(id: String, name: String) async throws {
        let _: CloudDevice = try await request("PUT", url: baseURL.appendingPathComponent("api/v1/devices"),
                                               body: CloudDevice(id: id, name: name))
    }

    // MARK: - Board

    enum DraftKind: String, Encodable { case task, story }

    struct ItemDraft: Decodable {
        let title: String
        let details: String
    }

    func generateDraft(projectId: String, kind: DraftKind, prompt: String) async throws -> ItemDraft {
        struct Input: Encodable {
            let projectId: String
            let kind: DraftKind
            let prompt: String
        }
        return try await request("POST", url: baseURL.appendingPathComponent("api/v1/agent/draft"),
                                 body: Input(projectId: projectId, kind: kind, prompt: prompt))
    }

    /// The board payload can hold hundreds of tasks, so it is decoded off the
    /// main actor — decoding it inline stalled scrolling on every sync.
    func board(projectId: String) async throws -> CloudRemoteBoard {
        let key = scope(projectId)
        let url = projectURL(projectId).appendingPathComponent("tasks")
        var baseline = key.flatMap { boards[$0] }
        let file = key.map { [baseURL.absoluteString, $0.account, $0.project, "board"] }
        if baseline == nil, let file {
            baseline = await snapshots.load(CloudRemoteBoard.self, key: file)
        }
        var cursor: String?
        var seen = Set<String>()
        var target: String?
        let initial = baseline
        let since = baseline?.checkpoint
        var useDelta = since != nil
        repeat {
            try Task.checkCancellation()
            guard key == scope(projectId) else { throw CancellationError() }
            var pageURL = url
            if useDelta, let since {
                pageURL.append(queryItems: [URLQueryItem(name: "since", value: since)])
                if let cursor { pageURL.append(queryItems: [URLQueryItem(name: "cursor", value: cursor)]) }
            }
            let data: Data
            do {
                data = try await performData(method: "GET", url: pageURL, body: nil)
            } catch AutopilotService.ServiceError.apiError(410, _) where useDelta {
                target = nil
                useDelta = false
                cursor = nil
                baseline = nil
                continue
            }
            let previous = baseline
            let delta = useDelta
            var (board, next) = try await Task.detached(priority: .userInitiated) {
                try CloudBoardPage.apply(data, to: delta ? previous : nil)
            }.value
            guard key == scope(projectId) else { throw CancellationError() }
            if let target, target != board.checkpoint { throw URLError(.cannotParseResponse) }
            target = board.checkpoint
            baseline = board
            cursor = next
            if let next, !seen.insert(next).inserted { throw URLError(.cannotParseResponse) }
            if next == nil {
                if let initial {
                    if let checkpoint = board.checkpoint {
                        board.matchesPreviousSnapshot = initial.checkpoint == checkpoint
                    } else {
                        board.matchesPreviousSnapshot = initial.tasks == board.tasks && initial.stories == board.stories &&
                            initial.members == board.members && initial.role == board.role && initial.currentUserId == board.currentUserId
                    }
                }
                try Task.checkCancellation()
                if let key { boards[key] = board }
                if let file, since != board.checkpoint {
                    await snapshots.store(board.checkpoint == nil ? nil : board, key: file)
                }
                guard scope(projectId) == key else { throw CancellationError() }
                return board
            }
        } while true
    }

    func createStory(projectId: String, fields: CloudStoryFields) async throws -> CloudRemoteStory {
        try await request("POST", url: projectURL(projectId).appendingPathComponent("stories"), body: fields)
    }

    func updateStory(projectId: String, storyId: String, fields: CloudStoryFields, previous: CloudStoryFields? = nil) async throws -> CloudRemoteStory {
        try await perform(method: "PATCH", url: projectURL(projectId).appendingPathComponent("stories/\(storyId)"), body: try CloudFieldPatch.encode(fields, previous: previous))
    }

    func deleteStory(projectId: String, storyId: String) async throws {
        try await delete(projectURL(projectId).appendingPathComponent("stories/\(storyId)"))
    }

    func createTask(projectId: String, fields: CloudTaskFields) async throws -> CloudRemoteTask {
        try await request("POST", url: projectURL(projectId).appendingPathComponent("tasks"), body: fields)
    }

    func updateTask(projectId: String, taskId: String, fields: CloudTaskFields, previous: CloudTaskFields? = nil) async throws -> CloudRemoteTask {
        try await perform(method: "PATCH", url: projectURL(projectId).appendingPathComponent("tasks/\(taskId)"), body: try CloudFieldPatch.encode(fields, previous: previous))
    }

    private struct ClaimTaskBody: Encodable { let deviceId: String }

    /// Autopilot's answer to a run claim: whether `deviceId` now owns the
    /// task, and the task as stored, naming its owner.
    struct TaskClaim: Decodable {
        let claimed: Bool
        let task: CloudRemoteTask
    }

    /// Assigns the task to `deviceId` only while no other laptop holds it.
    /// Autopilot applies this as one conditional update, so of several Macs
    /// racing for the same task exactly one gets `claimed == true`.
    func claimTask(projectId: String, taskId: String, deviceId: String) async throws -> TaskClaim {
        try await request(
            "POST",
            url: projectURL(projectId).appendingPathComponent("tasks/\(taskId)/claim"),
            body: ClaimTaskBody(deviceId: deviceId)
        )
    }

    func deleteTask(projectId: String, taskId: String) async throws {
        try await delete(projectURL(projectId).appendingPathComponent("tasks/\(taskId)"))
    }

    // MARK: - Saved views

    /// Nil means this server predates account-level saved views.
    func savedViews(projectId: String, revision: Int? = nil) async throws -> CloudSavedViews? {
        do {
            let key = scope(projectId)
            if let key, let revision, let cached = views[key], cached.revision == revision { return cached }
            let result: CloudSavedViews = try await request("GET", url: projectURL(projectId).appendingPathComponent("board-views"))
            guard key == scope(projectId) else { throw CancellationError() }
            if let key { views[key] = result }
            return result
        } catch where Self.isNotFound(error) { return nil }
    }

    func saveViews(_ settings: CloudSavedViews, projectId: String) async throws -> CloudSavedViews {
        try await request("PUT", url: projectURL(projectId).appendingPathComponent("board-views"), body: settings)
    }

    static func isConflict(_ error: Error) -> Bool {
        if case AutopilotService.ServiceError.apiError(409, _) = error { return true }
        return false
    }

    // MARK: - Transport

    /// Whether `error` means the row is already gone on the server.
    static func isNotFound(_ error: Error) -> Bool {
        if case AutopilotService.ServiceError.apiError(404, _) = error { return true }
        return false
    }

    /// Whether the server has the route but not this method — an older
    /// Autopilot without the endpoint.
    static func isMethodNotAllowed(_ error: Error) -> Bool {
        if case AutopilotService.ServiceError.apiError(405, _) = error { return true }
        return false
    }

    private struct Ignored: Decodable {}

    private func delete(_ url: URL) async throws {
        do {
            let _: Ignored = try await request("DELETE", url: url)
        } catch where Self.isNotFound(error) {
            // Already deleted elsewhere.
        }
    }

    private func request<T: Decodable>(_ method: String, url: URL) async throws -> T {
        try await perform(method: method, url: url, body: nil)
    }

    private func request<Body: Encodable, T: Decodable>(_ method: String, url: URL, body: Body) async throws -> T {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw AutopilotService.ServiceError.decodingError(error.localizedDescription)
        }
        return try await perform(method: method, url: url, body: payload)
    }

    /// Signs the request with the current bearer and retries once after a
    /// forced refresh on 401, like `AutopilotService`.
    private func perform<T: Decodable>(method: String, url: URL, body: Data?) async throws -> T {
        let data = try await performData(method: method, url: url, body: body)
        if T.self == Ignored.self { return Ignored() as! T }
        return try Self.decode(T.self, from: data)
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AutopilotService.ServiceError.decodingError(error.localizedDescription)
        }
    }

    private func performData(method: String, url: URL, body: Data?) async throws -> Data {
        func build(_ token: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            return request
        }

        let account = accountID()
        if let expected = Self.syncAccount, account != expected { throw CancellationError() }
        try Task.checkCancellation()
        guard let token = await tokenProvider(false) else {
            throw AutopilotService.ServiceError.notAuthenticated
        }
        guard account == accountID() else { throw CancellationError() }
        var (data, response) = try await session.data(for: build(token))
        guard account == accountID() else { throw CancellationError() }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            guard let refreshed = await tokenProvider(true) else {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw AutopilotService.ServiceError.notAuthenticated
            }
            guard account == accountID() else { throw CancellationError() }
            (data, response) = try await session.data(for: build(refreshed))
        }
        try Task.checkCancellation()
        guard account == accountID() else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else {
            throw AutopilotService.ServiceError.invalidResponse
        }
        if http.statusCode == 401 {
            NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
            throw AutopilotService.ServiceError.notAuthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "no body"
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public) failed: \(http.statusCode)")
            throw AutopilotService.ServiceError.apiError(http.statusCode, detail)
        }
        return data
    }

    /// Autopilot errors are `{ "error": "…" }`.
    private static func errorMessage(from data: Data) -> String? {
        struct Body: Decodable { let error: String }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }
}

/// A cursor and its complete baseline share one atomic, disposable cache file.
private actor CloudSnapshotCache {
    private func url(for key: [String]) throws -> URL {
        let dir = URL.cachesDirectory.appending(path: "FlowcyBoardSync/v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: try JSONEncoder().encode(key))
        return dir.appending(path: hash.map { String(format: "%02x", $0) }.joined())
    }

    func load<T: Decodable & Sendable>(_ type: T.Type, key: [String]) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: url(for: key)))
    }

    func store<T: Encodable & Sendable>(_ value: T?, key: [String]) {
        guard let file = try? url(for: key) else { return }
        if let value {
            try? JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
