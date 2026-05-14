import Foundation
import RxCodeCore
import os

actor OpenAISummarizationService {
    enum OpenAIError: LocalizedError {
        case invalidEndpoint
        case requestFailed(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Enter a valid OpenAI-compatible endpoint."
            case .requestFailed(let status, let message):
                return "OpenAI request failed (\(status)): \(message)"
            case .emptyResponse:
                return "OpenAI returned an empty response."
            }
        }
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "OpenAISummarizationService"
    )

    func fetchModels(endpoint: String, apiKey: String) async throws -> [String] {
        var request = try makeRequest(endpoint: endpoint, path: "/models", apiKey: apiKey)
        request.httpMethod = "GET"

        let value = try await send(request)
        let rawModels = value.objectValue?["data"]?.arrayValue
            ?? value.objectValue?["models"]?.arrayValue
            ?? value.arrayValue
            ?? []

        let models = rawModels.compactMap { item -> String? in
            if let id = item.stringValue { return id }
            return item.objectValue?["id"]?.stringValue
                ?? item.objectValue?["model"]?.stringValue
                ?? item.objectValue?["name"]?.stringValue
        }

        return Array(Set(models)).sorted()
    }

    func generateSessionTitle(firstUserMessage: String, endpoint: String, apiKey: String, model: String) async -> String? {
        let trimmedUser = String(firstUserMessage.prefix(500))
        let prompt = """
        Summarize the following user message as a 3-6 word chat title. Reply with ONLY the title, no quotes, no markdown, no punctuation at the end.

        \(trimmedUser)
        """

        let body: JSONValue = .object([
            "model": .string(model),
            "messages": .array([
                .object([
                    "role": .string("system"),
                    "content": .string("You generate concise chat titles.")
                ]),
                .object([
                    "role": .string("user"),
                    "content": .string(prompt)
                ])
            ]),
            "temperature": .number(0.2),
            "max_tokens": .number(32)
        ])

        do {
            var request = try makeRequest(endpoint: endpoint, path: "/chat/completions", apiKey: apiKey)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)

            let value = try await send(request)
            let content = value.objectValue?["choices"]?.arrayValue?.first?
                .objectValue?["message"]?.objectValue?["content"]?.stringValue
                ?? value.objectValue?["choices"]?.arrayValue?.first?
                    .objectValue?["text"]?.stringValue
            return cleanTitle(content)
        } catch {
            logger.warning("OpenAI title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeRequest(endpoint: String, path: String, apiKey: String) throws -> URLRequest {
        guard let url = endpointURL(endpoint: endpoint, path: path) else {
            throw OpenAIError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func endpointURL(endpoint: String, path: String) -> URL? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = AppState.defaultOpenAISummarizationEndpoint
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }

        if base.hasSuffix("/models") {
            base.removeLast("/models".count)
        } else if base.hasSuffix("/chat/completions") {
            base.removeLast("/chat/completions".count)
        }

        if let url = URL(string: base),
           url.host == "api.openai.com",
           url.path.isEmpty {
            base += "/v1"
        }

        return URL(string: base + path)
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw OpenAIError.requestFailed(status, message)
        }
        guard !data.isEmpty else { throw OpenAIError.emptyResponse }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }

        let lower = cleaned.lowercased()
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "openai error"]
        guard !errorPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return String(cleaned.prefix(80))
    }
}
