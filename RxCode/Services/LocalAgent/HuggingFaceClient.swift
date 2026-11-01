import Foundation

/// The parts of the Hugging Face Hub API the model browser uses. Requests
/// carry the signed-in account's token when there is one, which unlocks the
/// user's private repos and gated repos they were granted; public repos need none.
nonisolated enum HuggingFaceClient {
    static let base = URL(string: "https://huggingface.co")!

    enum ClientError: LocalizedError {
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(401): "This repository is private or gated. Sign in to Hugging Face with an account that can access it."
            case .http(403): "Your Hugging Face account can't access this repository. Gated models need access requested on their Hugging Face page first."
            case .http(404): "Hugging Face couldn't find this repository. Private repositories need a signed-in account."
            case .http(let status): "Hugging Face returned HTTP \(status)."
            case .malformed: "Hugging Face returned an unexpected response."
            }
        }
    }

    /// First page of `format` repos matching `query`, most downloaded first.
    /// Later pages are fetched on demand with `page(at:format:)`.
    /// With `author`, lists that user's repos instead of the whole catalog —
    /// including private ones when `author` is the signed-in account.
    static func search(
        _ query: String, format: LocalModelWeightFormat = .gguf, author: String? = nil, category: String? = nil, limit: Int = 30
    ) async throws -> HFModelPage {
        return try await page(at: searchURL(query, format: format, author: author, category: category, limit: limit), format: format)
    }

    static func searchURL(
        _ query: String, format: LocalModelWeightFormat, author: String? = nil,
        category: String? = nil, limit: Int = 30
    ) -> URL {
        var components = URLComponents(url: base.appending(path: "api/models"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "filter", value: format.rawValue),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let category { items.append(URLQueryItem(name: "pipeline_tag", value: category)) }
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        items += expandItems
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
        components.queryItems = items
        return components.url!
    }

    struct Category: Identifiable, Sendable {
        let id: String
        let label: String
    }

    /// Use the Hub's task catalog so newly supported categories appear automatically.
    static func categories() async throws -> [Category] {
        guard let tasks = try await fetchJSON(base.appending(path: "api/tasks")) as? [String: [String: Any]] else {
            throw ClientError.malformed
        }
        return tasks.compactMap { id, task in
            guard let label = task["label"] as? String else { return nil }
            return Category(id: id, label: label)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// One page of search results, plus the link to the next page if any.
    static func page(at url: URL, format: LocalModelWeightFormat) async throws -> HFModelPage {
        let (json, response) = try await fetch(url)
        guard let array = json as? [[String: Any]] else { throw ClientError.malformed }
        return HFModelPage(
            models: array.compactMap { summary($0, format: format) },
            next: nextPageURL(fromLinkHeader: response.value(forHTTPHeaderField: "Link"))
        )
    }

    static func model(_ repoID: String, format: LocalModelWeightFormat = .gguf) async throws -> HFModelSummary {
        var components = URLComponents(url: base.appending(path: "api/models/\(repoID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = expandItems
        guard let object = try await fetchJSON(components.url!) as? [String: Any], let summary = summary(object, format: format) else {
            throw ClientError.malformed
        }
        return summary
    }

    /// `<https://…&cursor=…>; rel="next"` → the URL.
    static func nextPageURL(fromLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for link in header.split(separator: ",") where link.contains(#"rel="next""#) {
            guard let open = link.firstIndex(of: "<"), let close = link.firstIndex(of: ">"), open < close else { continue }
            return URL(string: String(link[link.index(after: open)..<close]))
        }
        return nil
    }

    /// Downloadable variants of a repo. GGUF repos hold one per quantization;
    /// an MLX repo is a single quantization, downloaded whole.
    static func variants(of summary: HFModelSummary) async throws -> [HFModelVariant] {
        switch summary.format {
        case .gguf: try await variants(of: summary.id)
        case .mlx: try await mlxVariant(of: summary.id).map { [$0] } ?? []
        }
    }

    /// Every file of an MLX repo, or nil when it has no safetensors weights.
    static func mlxVariant(of repoID: String) async throws -> HFModelVariant? {
        var components = URLComponents(url: base.appending(path: "api/models/\(repoID)/tree/main"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let entries = try await fetchJSON(components.url!) as? [[String: Any]] else { throw ClientError.malformed }
        let files = mlxFiles(entries)
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { return nil }
        let bits = try? await mlxConfig(of: repoID).bits
        return HFModelVariant(
            files: files.map(\.path).sorted(),
            sizeBytes: files.reduce(0) { $0 + $1.size },
            quantization: LocalModelFormat.mlxQuantization(repoID: repoID, bits: bits)
        )
    }

    /// The files native MLX needs: weights, config and tokenizer — not the
    /// README, images or git metadata.
    static func mlxFiles(_ entries: [[String: Any]]) -> [(path: String, size: Int64)] {
        let skipped = [".gitattributes", ".md", ".png", ".jpg", ".jpeg", ".gif", ".pdf"]
        return entries.compactMap { entry in
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String,
                  !skipped.contains(where: { path.lowercased().hasSuffix($0) }) else { return nil }
            let lfs = entry["lfs"] as? [String: Any]
            return (path, (lfs?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Context length and quantization bits from an MLX repo's `config.json`.
    static func mlxConfig(of repoID: String) async throws -> (contextLength: Int?, bits: Int?) {
        guard let config = try await fetchJSON(downloadURL(repoID: repoID, file: "config.json")) as? [String: Any] else {
            throw ClientError.malformed
        }
        // Multimodal configs nest the language model's settings.
        let text = config["text_config"] as? [String: Any]
        let context = (config["max_position_embeddings"] as? NSNumber) ?? (text?["max_position_embeddings"] as? NSNumber)
        let quantization = (config["quantization"] as? [String: Any]) ?? (config["quantization_config"] as? [String: Any])
        return (context?.intValue, (quantization?["bits"] as? NSNumber)?.intValue)
    }

    /// Downloadable GGUF variants of a repo, smallest first. Split files
    /// (`…-00001-of-00003.gguf`) are grouped into one variant; vision
    /// projector files (`mmproj`) are left out.
    static func variants(of repoID: String) async throws -> [HFModelVariant] {
        let url = base.appending(path: "api/models/\(repoID)/tree/main")
        guard let entries = try await fetchJSON(url) as? [[String: Any]] else { throw ClientError.malformed }
        var files: [(path: String, size: Int64)] = []
        for entry in entries {
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String,
                  path.lowercased().hasSuffix(".gguf"), !path.lowercased().contains("mmproj") else { continue }
            let lfs = entry["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value ?? 0
            files.append((path, size))
        }
        // Nested quantization folders (`Q4_K_M/model-00001-of-00002.gguf`) are
        // common for large repos; the tree endpoint lists only the top level,
        // so descend one level into directories as well.
        for entry in entries where (entry["type"] as? String) == "directory" {
            guard let path = entry["path"] as? String,
                  let nested = try? await fetchJSON(base.appending(path: "api/models/\(repoID)/tree/main/\(path)")) as? [[String: Any]]
            else { continue }
            for child in nested {
                guard let childPath = child["path"] as? String, childPath.lowercased().hasSuffix(".gguf"),
                      !childPath.lowercased().contains("mmproj") else { continue }
                let lfs = child["lfs"] as? [String: Any]
                files.append((childPath, (lfs?["size"] as? NSNumber)?.int64Value ?? (child["size"] as? NSNumber)?.int64Value ?? 0))
            }
        }
        return group(files).sorted { $0.sizeBytes < $1.sizeBytes }
    }

    static func group(_ files: [(path: String, size: Int64)]) -> [HFModelVariant] {
        let splitPattern = #/-(\d{5})-of-(\d{5})\.gguf$/#
        var singles: [HFModelVariant] = []
        var splits: [String: [(path: String, size: Int64)]] = [:]
        for file in files {
            if let match = file.path.firstMatch(of: splitPattern) {
                let key = String(file.path[..<match.range.lowerBound])
                splits[key, default: []].append(file)
            } else {
                singles.append(HFModelVariant(
                    files: [file.path], sizeBytes: file.size,
                    quantization: LocalModelFormat.quantization(from: file.path)
                ))
            }
        }
        for (key, parts) in splits {
            let ordered = parts.sorted { $0.path < $1.path }
            singles.append(HFModelVariant(
                files: ordered.map(\.path),
                sizeBytes: ordered.reduce(0) { $0 + $1.size },
                quantization: LocalModelFormat.quantization(from: key)
            ))
        }
        return singles
    }

    static func downloadURL(repoID: String, file: String) -> URL {
        base.appending(path: "\(repoID)/resolve/main/\(file)")
    }

    /// The repo's model card (`README.md`) as renderable markdown — its YAML
    /// metadata header removed and inline HTML converted — or nil when the
    /// repo has none.
    static func modelCard(of repoID: String) async throws -> String? {
        let (data, http) = try await fetchData(downloadURL(repoID: repoID, file: "README.md"))
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
        let card = ModelCardMarkdown.normalize(stripFrontMatter(String(decoding: data, as: UTF8.self)))
        return card.isEmpty ? nil : card
    }

    /// Drops a leading `---` … `---` YAML block, which holds the card's
    /// metadata (license, tags) rather than its description.
    static func stripFrontMatter(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return markdown }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// Every file in a repo with its size, folders included, for the video
    /// companion lookup. Capped so a huge repo can't flood the task model.
    static func files(of repoID: String, limit: Int = 400) async throws -> [(path: String, size: Int64)] {
        var components = URLComponents(url: base.appending(path: "api/models/\(repoID)/tree/main"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = components?.url, let entries = try await fetchJSON(url) as? [[String: Any]] else {
            throw ClientError.malformed
        }
        return entries.prefix(limit * 2).compactMap { entry in
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String else { return nil }
            let lfs = entry["lfs"] as? [String: Any]
            return (path, (lfs?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
        .prefix(limit)
        .map { $0 }
    }

    /// The `general.*` metadata of a GGUF file (architecture, name, …), read
    /// from its first bytes with a range request instead of a download. Empty
    /// for diffusion GGUFs, which carry none.
    static func ggufMetadata(repoID: String, file: String) async throws -> [String: String] {
        let (data, http) = try await fetchData(downloadURL(repoID: repoID, file: file), range: "bytes=0-262143")
        guard (200...299).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
        return GGUFHeader.generalMetadata(in: data)
    }

    // MARK: - Private

    private static let expandItems = ["gguf", "safetensors", "config", "author", "downloads", "likes", "lastModified",
                                      "private", "gated", "pipeline_tag", "library_name", "tags"]
        .map { URLQueryItem(name: "expand[]", value: $0) }

    private static func fetchJSON(_ url: URL) async throws -> Any {
        try await fetch(url).json
    }

    private static func fetch(_ url: URL) async throws -> (json: Any, response: HTTPURLResponse) {
        let (data, http) = try await fetchData(url, accept: "application/json")
        return try decode(data, http)
    }

    /// Retries once with a refreshed token when the Hub rejects the current one.
    private static func fetchData(_ url: URL, accept: String? = nil, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let token = try await HuggingFaceCredentials.shared.accessToken()
        let (data, http) = try await send(url, token: token, accept: accept, range: range)
        if http.statusCode == 401, let token,
           let renewed = try await HuggingFaceCredentials.shared.accessToken(rejecting: token) {
            return try await send(url, token: renewed, accept: accept, range: range)
        }
        return (data, http)
    }

    private static func send(_ url: URL, token: String?, accept: String?, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: HuggingFaceRedirectGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformed }
        return (data, http)
    }

    private static func decode(_ data: Data, _ http: HTTPURLResponse) throws -> (json: Any, response: HTTPURLResponse) {
        guard (200...299).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
        return (try JSONSerialization.jsonObject(with: data), http)
    }

    static func summary(_ object: [String: Any], format: LocalModelWeightFormat) -> HFModelSummary? {
        guard let id = object["id"] as? String else { return nil }
        let gguf = object["gguf"] as? [String: Any]
        let safetensors = object["safetensors"] as? [String: Any]
        let config = object["config"] as? [String: Any]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return HFModelSummary(
            id: id,
            author: (object["author"] as? String) ?? String(id.split(separator: "/").first ?? ""),
            downloads: (object["downloads"] as? NSNumber)?.intValue ?? 0,
            likes: (object["likes"] as? NSNumber)?.intValue ?? 0,
            parameterCount: ((gguf?["total"] ?? safetensors?["total"]) as? NSNumber)?.int64Value,
            contextLength: (gguf?["context_length"] as? NSNumber)?.intValue,
            architecture: (gguf?["architecture"] ?? config?["model_type"]) as? String,
            lastModified: (object["lastModified"] as? String).flatMap(formatter.date(from:)),
            format: format,
            isPrivate: (object["private"] as? Bool) ?? false,
            // `gated` is `false`, `"auto"` or `"manual"`.
            isGated: object["gated"].map { !(($0 as? Bool) == false) } ?? false,
            pipelineTag: object["pipeline_tag"] as? String,
            libraryName: object["library_name"] as? String,
            tags: object["tags"] as? [String] ?? []
        )
    }
}
