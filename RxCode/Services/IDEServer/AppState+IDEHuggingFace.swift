import Foundation
import RxCodeCore

extension AppState {
    func handleSearchHuggingFaceModels(arguments: JSONValue) async throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue else {
            throw IDEToolError.invalidArguments("missing 'query'")
        }
        let format = arguments["format"]?.stringValue ?? "all"
        guard ["all", "gguf", "mlx"].contains(format) else {
            throw IDEToolError.invalidArguments("format must be all, gguf, or mlx")
        }
        let requestedLimit = arguments["limit"]?.numberValue ?? 10
        guard requestedLimit >= 1, requestedLimit <= 30, requestedLimit.rounded() == requestedLimit else {
            throw IDEToolError.invalidArguments("limit must be an integer from 1 to 30")
        }
        let limit = Int(requestedLimit)
        let formats: [LocalModelWeightFormat] = format == "all" ? [.gguf, .mlx] : [LocalModelWeightFormat(rawValue: format)!]
        var models: [HFModelSummary] = []
        for format in formats {
            let page = try await HuggingFaceClient.search(query, format: format,
                category: arguments["category"]?.stringValue, limit: limit)
            models += page.models
        }
        let results: [JSONValue] = models.sorted { $0.downloads > $1.downloads }.prefix(limit).map { model in
            .object([
                "repo_id": .string(model.id),
                "format": .string(model.format.rawValue),
                "category": model.pipelineTag.map(JSONValue.string) ?? .null,
                "library": model.libraryName.map(JSONValue.string) ?? .null,
                "downloads": .number(Double(model.downloads)),
                "gated": .bool(model.isGated),
                "private": .bool(model.isPrivate),
                "repository_url": .string(HuggingFaceClient.base.appending(path: model.id).absoluteString),
                "open_url": .string(LocalModelSheetRequest(repoID: model.id, format: model.format).url.absoluteString),
            ])
        }
        return jsonTextResult(.object(["models": .array(results)]))
    }
}
