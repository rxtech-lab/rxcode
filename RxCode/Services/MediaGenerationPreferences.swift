import Foundation
import Observation
import RxCodeCore

nonisolated enum MediaGenerationKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case image, video, audio
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func supports(_ model: LocalModelInfo) -> Bool {
        model.studioKind == studio && (self != .audio || LocalAudioMode(model: model) == .speech)
    }
    var studio: LocalStudioKind {
        switch self { case .image: .image; case .video: .video; case .audio: .audio }
    }
}

nonisolated struct MediaGenerationSelection: Codable, Hashable, Sendable {
    enum Provider: String, CaseIterable, Codable, Sendable { case codex, local, flowcy }
    var provider: Provider
    var model: String
    static let codex = Self(provider: .codex, model: "")
    var key: String { "\(provider.rawValue):\(model)" }
}

@MainActor @Observable
final class MediaGenerationPreferences {
    static let shared = MediaGenerationPreferences()
    private static let key = "media.generation.selections.v1"
    var selections: [String: MediaGenerationSelection] {
        didSet { if let data = try? JSONEncoder().encode(selections) { defaults.set(data, forKey: Self.key) } }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selections = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: MediaGenerationSelection].self, from: $0) } ?? ["image": .codex]
    }
    func selection(_ kind: MediaGenerationKind) -> MediaGenerationSelection? {
        selections[kind.rawValue]
    }
}

nonisolated struct FlowcyMediaModel: Decodable, Identifiable, Sendable {
    let modelId: String
    let alias: String
    let provider: String
    let labels: [String]
    var id: String { modelId }
}

/// Uses the native account token; provider secrets stay on the Flowcy server.
@MainActor
struct FlowcyMediaClient {
    private let accessToken: @MainActor (Bool) async -> String?
    let baseURL: URL

    init(auth: RxAuthService) {
        self.init(baseURL: Self.defaultBaseURL) { await auth.accessToken(forceRefresh: $0) }
    }

    init(baseURL: URL, accessToken: @escaping @MainActor (Bool) async -> String?) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    private static var defaultBaseURL: URL {
        URL(string: "https://www.flowcy.dev/api/v1")!
    }

    func request(_ path: String, body: JSONValue? = nil, idempotencyKey: String = UUID().uuidString) async throws -> JSONValue {
        for refresh in [false, true] {
            guard let token = await accessToken(refresh) else {
                throw IDEToolError.handlerFailed("Sign in to Flowcy in Settings first.")
            }
            var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 310)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = try body.map { try JSONEncoder().encode($0) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if body != nil { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw IDEToolError.handlerFailed("Invalid Flowcy response.") }
            if http.statusCode == 401 && !refresh { continue }
            let payload = try await Self.readResponse(bytes, status: http.statusCode)
            guard (200..<300).contains(http.statusCode) else {
                let error = payload["error"]?.stringValue
                throw IDEToolError.handlerFailed(error ?? "Flowcy media request failed (HTTP \(http.statusCode)).")
            }
            return payload
        }
        throw IDEToolError.handlerFailed("Flowcy sign-in expired.")
    }

    @concurrent nonisolated private static func readResponse(_ bytes: URLSession.AsyncBytes, status: Int) async throws -> JSONValue {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 48_000_000 else { throw IDEToolError.handlerFailed("Flowcy media response exceeds 48 MB.") }
            data.append(byte)
        }
        if let payload = try? JSONDecoder().decode(JSONValue.self, from: data) { return payload }
        if !(200..<300).contains(status) { return .object([:]) }
        throw IDEToolError.handlerFailed("Flowcy returned an invalid JSON response.")
    }

    func allModels() async throws -> [FlowcyMediaModel] {
        // The public catalog returns one row per capability, with the original labels.
        let response = try await request("models")
        struct Model: Decodable { let id: String; let displayName: String; let provider: String; let labels: [String] }
        struct Catalog: Decodable { let models: [Model] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(response))
        var seen = Set<String>()
        return catalog.models.filter { seen.insert($0.id).inserted }.map {
            FlowcyMediaModel(modelId: $0.id, alias: $0.displayName, provider: $0.provider, labels: $0.labels)
        }
    }
}
