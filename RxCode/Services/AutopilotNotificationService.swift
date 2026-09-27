import Foundation
import RxCodeCore
import os

/// Talks to github-pm's notification API (same host as `AutopilotService`,
/// `https://autopilot.rxlab.app`) using the rxauth bearer: sends notifications,
/// uploads their attachments, and manages trusted recipient emails. Transport
/// mirrors `DocsService`.
@MainActor
final class AutopilotNotificationService {

    enum ServiceError: LocalizedError {
        case notAuthenticated
        case invalidResponse
        case apiError(Int, String)
        case decodingError(String)
        case uploadFailed(Int)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in. Please sign in with rxlab."
            case .invalidResponse:
                return "Received an invalid response from the notification service."
            case .apiError(let code, let detail):
                return Self.serverMessage(detail) ?? "Notification service error (\(code)): \(detail)"
            case .decodingError(let detail):
                return "Failed to decode notification response: \(detail)"
            case .uploadFailed(let code):
                return "Uploading the attachment failed (\(code))."
            }
        }

        /// The `error` field of a JSON error body, if present.
        private static func serverMessage(_ body: String) -> String? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["error"] as? String, !message.isEmpty
            else { return nil }
            return message
        }
    }

    private let rxAuth: RxAuthService
    private let logger = Logger(subsystem: "com.claudework", category: "AutopilotNotificationService")
    private let session: URLSession = .shared

    init(rxAuth: RxAuthService) {
        self.rxAuth = rxAuth
    }

    var baseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://autopilot.rxlab.app")!
    }

    // MARK: - Notifications

    /// `POST /api/v1/notifications` — sends through the account's channel
    /// (email) and counts against the daily quota.
    func send(_ request: SendAutopilotNotificationRequest) async throws -> AutopilotNotification {
        try await send(method: "POST", url: url("/api/v1/notifications"), body: request)
    }

    /// `GET /api/v1/notifications/usage` — today's quota.
    func usage() async throws -> AutopilotNotificationUsage {
        try await get(url: url("/api/v1/notifications/usage"))
    }

    // MARK: - Attachments

    /// Registers an attachment and uploads `data` to the returned presigned
    /// URL. Returns the attachment id to reference when sending.
    func uploadAttachment(data: Data, filename: String, contentType: String) async throws -> String {
        let registration: NotificationAttachmentUpload = try await send(
            method: "POST",
            url: url("/api/v1/notifications/attachments"),
            body: CreateNotificationAttachmentRequest(filename: filename, contentType: contentType, size: data.count)
        )
        guard let uploadURL = URL(string: registration.upload.url) else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = registration.upload.method
        for (field, value) in registration.upload.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            try? await deleteAttachment(id: registration.attachment.id)
            throw ServiceError.uploadFailed(http.statusCode)
        }
        return registration.attachment.id
    }

    /// `DELETE /api/v1/notifications/attachments/{id}` — drops an unsent upload.
    func deleteAttachment(id: String) async throws {
        let _: Ignored = try await send(method: "DELETE", url: url("/api/v1/notifications/attachments/\(seg(id))"))
    }

    // MARK: - Trusted emails

    func listTrustedEmails() async throws -> TrustedEmailList {
        try await get(url: url("/api/v1/notifications/trusted-emails"))
    }

    /// Adds `email` (or re-sends the link for an unverified one). The owner
    /// must confirm the emailed link before notifications can go there.
    func addTrustedEmail(_ email: String) async throws -> TrustedEmail {
        let locale = Locale.current.language.languageCode?.identifier
        let response: TrustedEmailResponse = try await send(
            method: "POST",
            url: url("/api/v1/notifications/trusted-emails"),
            body: AddTrustedEmailRequest(email: email, locale: locale)
        )
        return response.trustedEmail
    }

    func removeTrustedEmail(id: String) async throws {
        let _: Ignored = try await send(method: "DELETE", url: url("/api/v1/notifications/trusted-emails/\(seg(id))"))
    }

    // MARK: - URL building

    private func seg(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func url(_ path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = components.percentEncodedPath + path
        return components.url!
    }

    // MARK: - Transport (mirrors DocsService)

    private struct Ignored: Decodable {}

    private func get<T: Decodable>(url: URL) async throws -> T {
        try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func send<Body: Encodable, T: Decodable>(method: String, url: URL, body: Body) async throws -> T {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw ServiceError.decodingError(error.localizedDescription)
        }
        return try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            return request
        }
    }

    private func send<T: Decodable>(method: String, url: URL) async throws -> T {
        try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func performWithRetry<T: Decodable>(_ build: (String) -> URLRequest) async throws -> T {
        guard let token = await rxAuth.accessToken() else {
            throw ServiceError.notAuthenticated
        }
        let request = build(token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }

        if http.statusCode == 401 {
            guard let refreshed = await rxAuth.accessToken(forceRefresh: true) else {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw ServiceError.notAuthenticated
            }
            let retried = build(refreshed)
            let (data2, response2) = try await session.data(for: retried)
            guard let http2 = response2 as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            if http2.statusCode == 401 {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw ServiceError.notAuthenticated
            }
            return try decode(data: data2, response: http2)
        }
        return try decode(data: data, response: http)
    }

    private func decode<T: Decodable>(data: Data, response: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw ServiceError.apiError(response.statusCode, body)
        }
        if T.self == Ignored.self {
            return Ignored() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.decodingError(error.localizedDescription)
        }
    }
}
