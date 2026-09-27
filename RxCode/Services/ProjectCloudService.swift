import Foundation
import RxCodeCore
import os

/// Talks to Autopilot's project board API (`/api/v1/docs/repositories`) with
/// the rxauth bearer, so cloud projects and their stories and tasks sync to
/// every device signed in to the same account.
@MainActor
final class ProjectCloudService {

    private let tokenProvider: (Bool) async -> String?
    private let configuredBaseURL: URL?
    private let logger = Logger(subsystem: "com.claudework", category: "ProjectCloudService")
    private let session: URLSession

    convenience init(rxAuth: RxAuthService) {
        self.init(session: .shared, baseURL: nil) { forceRefresh in
            await rxAuth.accessToken(forceRefresh: forceRefresh)
        }
    }

    init(session: URLSession, baseURL: URL?, tokenProvider: @escaping (Bool) async -> String?) {
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
        return URL(string: "https://autopilot.rxlab.app")!
    }

    private var projectsURL: URL { baseURL.appendingPathComponent("/api/v1/docs/repositories") }

    private func projectURL(_ id: String) -> URL { projectsURL.appendingPathComponent(id) }

    // MARK: - Projects

    /// Every Autopilot project the signed-in user can access, across pages.
    func listProjects() async throws -> [CloudProject] {
        var all: [CloudProject] = []
        var cursor: String?
        repeat {
            var components = URLComponents(url: projectsURL, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "pageSize", value: "100")]
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

    /// The board payload can hold hundreds of tasks, so it is decoded off the
    /// main actor — decoding it inline stalled scrolling on every sync.
    func board(projectId: String) async throws -> CloudRemoteBoard {
        let data = try await performData(method: "GET", url: projectURL(projectId).appendingPathComponent("tasks"), body: nil)
        return try await Task.detached(priority: .userInitiated) {
            try Self.decode(CloudRemoteBoard.self, from: data)
        }.value
    }

    func createStory(projectId: String, fields: CloudStoryFields) async throws -> CloudRemoteStory {
        try await request("POST", url: projectURL(projectId).appendingPathComponent("stories"), body: fields)
    }

    func updateStory(projectId: String, storyId: String, fields: CloudStoryFields) async throws -> CloudRemoteStory {
        try await request("PATCH", url: projectURL(projectId).appendingPathComponent("stories/\(storyId)"), body: fields)
    }

    func deleteStory(projectId: String, storyId: String) async throws {
        try await delete(projectURL(projectId).appendingPathComponent("stories/\(storyId)"))
    }

    func createTask(projectId: String, fields: CloudTaskFields) async throws -> CloudRemoteTask {
        try await request("POST", url: projectURL(projectId).appendingPathComponent("tasks"), body: fields)
    }

    func updateTask(projectId: String, taskId: String, fields: CloudTaskFields) async throws -> CloudRemoteTask {
        try await request("PATCH", url: projectURL(projectId).appendingPathComponent("tasks/\(taskId)"), body: fields)
    }

    func deleteTask(projectId: String, taskId: String) async throws {
        try await delete(projectURL(projectId).appendingPathComponent("tasks/\(taskId)"))
    }

    // MARK: - Transport

    /// Whether `error` means the row is already gone on the server.
    static func isNotFound(_ error: Error) -> Bool {
        if case AutopilotService.ServiceError.apiError(404, _) = error { return true }
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

        guard let token = await tokenProvider(false) else {
            throw AutopilotService.ServiceError.notAuthenticated
        }
        var (data, response) = try await session.data(for: build(token))
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            guard let refreshed = await tokenProvider(true) else {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw AutopilotService.ServiceError.notAuthenticated
            }
            (data, response) = try await session.data(for: build(refreshed))
        }
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
