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

    func generateResponseNotificationSummary(responseText: String, endpoint: String, apiKey: String, model: String) async -> String? {
        let trimmedResponse = String(responseText.prefix(4000))
        let prompt = """
        Summarize the following assistant response for a macOS notification. Reply with one concise sentence under 180 characters. Mention the outcome and the most important result. No markdown.

        \(trimmedResponse)
        """

        let body: JSONValue = .object([
            "model": .string(model),
            "messages": .array([
                .object([
                    "role": .string("system"),
                    "content": .string("You write concise notification summaries.")
                ]),
                .object([
                    "role": .string("user"),
                    "content": .string(prompt)
                ])
            ]),
            "temperature": .number(0.2),
            "max_tokens": .number(64)
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
            return cleanNotificationSummary(content)
        } catch {
            logger.warning("OpenAI notification summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String,
        endpoint: String,
        apiKey: String,
        model: String
    ) async -> String? {
        let previous = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Update the stored summary for one project thread. Use the previous summary, latest user request, and final assistant response.
        Keep it factual and concise, 3-6 bullet points max. Include completed work, important decisions, files or areas touched, and unresolved follow-ups.
        Reply with only the updated summary.

        Previous summary:
        \((previous?.isEmpty == false) ? previous! : "None")

        Latest user request:
        \(String(userMessage.prefix(2000)))

        Final assistant response:
        \(String(finalResponse.prefix(4000)))
        """
        return await generateSummary(prompt: prompt, endpoint: endpoint, apiKey: apiKey, model: model, maxTokens: 256)
    }

    func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)],
        endpoint: String,
        apiKey: String,
        model: String
    ) async -> String? {
        guard !threadSummaries.isEmpty else { return nil }
        let prompt = Self.branchBriefingPrompt(threadSummaries: threadSummaries)
        return await generateSummary(prompt: prompt, endpoint: endpoint, apiKey: apiKey, model: model, maxTokens: 384)
    }

    static func branchBriefingPrompt(threadSummaries: [(title: String, summary: String)]) -> String {
        let joined = threadSummaries.map { item -> String in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(item.summary.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "### \(title.isEmpty ? "Untitled thread" : title)\n\(summary)"
        }.joined(separator: "\n\n")

        return """
        Write a concise overall briefing for one git branch by synthesizing the per-thread summaries below into a single coherent overview.
        Cover the main themes, completed work, important decisions, files or areas touched, and unresolved follow-ups across the whole branch.
        Do not list threads individually — produce a unified summary. Use 4-8 short bullet points. Reply with only the briefing.

        Thread summaries (newest first):

        \(joined)
        """
    }

    private func generateSummary(prompt: String, endpoint: String, apiKey: String, model: String, maxTokens: Double) async -> String? {
        let body: JSONValue = .object([
            "model": .string(model),
            "messages": .array([
                .object([
                    "role": .string("system"),
                    "content": .string("You maintain concise local project summaries.")
                ]),
                .object([
                    "role": .string("user"),
                    "content": .string(prompt)
                ])
            ]),
            "temperature": .number(0.2),
            "max_tokens": .number(maxTokens)
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
            return cleanSummary(content, limit: 1800)
        } catch {
            logger.warning("OpenAI summary generation failed: \(error.localizedDescription)")
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

    private func cleanNotificationSummary(_ raw: String?) -> String? {
        cleanSummary(raw, limit: 180)
    }

    private func cleanSummary(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }

        let lower = cleaned.lowercased()
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "openai error"]
        guard !errorPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return String(cleaned.prefix(limit))
    }
}
