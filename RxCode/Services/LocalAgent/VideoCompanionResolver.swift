import Foundation
import os

/// Asks the user's default task model which companion files a local video
/// model needs — the text encoder and the two VAEs — instead of hardcoding
/// them per quantization.
///
/// The task model is reached through one-shot completions, so the lookup is a
/// small tool loop over JSON: each round the model either calls one read-only
/// Hugging Face tool (list a repo's files, read its model card, read a GGUF
/// header) or answers. The whole transcript is resent every round. Answers
/// are only accepted for files RxCode has itself seen in a repo listing, so a
/// made-up path can never be downloaded. The `sd-cli` flags are not part of
/// the answer; they stay with the model family (`LocalVideoRecipe`).
nonisolated struct VideoCompanionResolver {
    /// The default task model, as the resolver talks to it.
    struct TaskModel: Sendable {
        /// "Claude · Haiku" — shown beside the steps it takes.
        let label: String
        let complete: @Sendable (_ prompt: String) async -> String?
    }

    /// Read-only Hugging Face lookups; replaceable in tests.
    struct Sources: Sendable {
        var files: @Sendable (_ repoID: String) async throws -> [(path: String, size: Int64)]
        var modelCard: @Sendable (_ repoID: String) async throws -> String?
        var ggufMetadata: @Sendable (_ repoID: String, _ file: String) async throws -> [String: String]

        var search: @Sendable (_ query: String) async throws -> [String] = { query in
            try await HuggingFaceClient.search(query, limit: 20).models.map(\.id)
        }

        static let huggingFace = Sources(
            files: { try await HuggingFaceClient.files(of: $0) },
            modelCard: { try await HuggingFaceClient.modelCard(of: $0) },
            ggufMetadata: { try await HuggingFaceClient.ggufMetadata(repoID: $0, file: $1) }
        )
    }

    enum ResolveError: LocalizedError {
        case noReply
        case gaveUp

        var errorDescription: String? {
            switch self {
            case .noReply: "The task model didn't reply."
            case .gaveUp: "The task model couldn't settle on the companion files."
            }
        }
    }

    /// One reply from the task model.
    enum Step: Equatable {
        case searchModels(query: String)
        case listFiles(repo: String)
        case readCard(repo: String)
        case ggufInfo(repo: String, file: String)
        case answer(textEncoder: LocalVideoRecipe.Companion, videoVAE: LocalVideoRecipe.Companion,
                    audioVAE: LocalVideoRecipe.Companion)
    }

    let taskModel: TaskModel
    var sources: Sources = .huggingFace
    /// `(status, actor)`: actor is the task model's label for its own steps.
    let report: @Sendable (_ status: String, _ actor: String?) -> Void
    var maxRounds = 8

    private static let logger = Logger(subsystem: "com.rxlab.RxCode", category: "VideoCompanionResolver")
    static let cardLimit = 12_000

    func resolve(model: LocalModelInfo) async throws -> LocalVideoRecipe {
        let denoiser = model.files.first ?? ""
        var listings: [String: [String: Int64]] = [:]
        var transcript: [String] = []

        // The denoiser's own repo and card answer most lookups, so they are
        // gathered up front instead of costing the model two rounds.
        report("Reading \(model.repoID)…", nil)
        transcript.append(await run(.listFiles(repo: model.repoID), listings: &listings))
        transcript.append(await run(.readCard(repo: model.repoID), listings: &listings))

        for round in 0..<maxRounds {
            try Task.checkCancellation()
            let prompt = Self.prompt(repoID: model.repoID, denoiser: denoiser,
                                     size: model.sizeBytes, transcript: transcript, isLastRound: round == maxRounds - 1)
            guard let reply = await taskModel.complete(prompt) else { throw ResolveError.noReply }
            try Task.checkCancellation()
            guard let (status, step) = Self.parse(reply) else {
                Self.logger.warning("Unreadable reply: \(reply.prefix(300), privacy: .public)")
                transcript.append("### Your previous reply\nIt was not one JSON object in the required shape. Reply with JSON only.")
                continue
            }
            if let status { report(status, taskModel.label) }

            guard case .answer(let encoder, let video, let audio) = step else {
                transcript.append(await run(step, listings: &listings))
                continue
            }
            let recipe = LocalVideoRecipe(textEncoder: encoder, videoVAE: video, audioVAE: audio)
            // Listings for repos the model named but never listed.
            for repo in Set(recipe.companions.map(\.repoID)) where listings[repo] == nil {
                _ = await run(.listFiles(repo: repo), listings: &listings)
            }
            if let problem = Self.problem(with: recipe, denoiser: denoiser, listings: listings) {
                report("Checking the answer: \(problem)", nil)
                transcript.append("### Your answer was rejected\n\(problem) Fix it and answer again.")
                continue
            }
            for (role, companion) in zip(["Text encoder", "Video VAE", "Audio VAE"], recipe.companions) {
                let size = listings[companion.repoID]?[companion.file].map(Self.formatBytes) ?? "?"
                report("\(role): \(companion.localName) (\(size)) from \(companion.repoID)", taskModel.label)
            }
            return recipe
        }
        throw ResolveError.gaveUp
    }

    /// Runs one tool call; returns its transcript entry.
    private func run(_ step: Step, listings: inout [String: [String: Int64]]) async -> String {
        do {
            switch step {
            case .searchModels(let query):
                let repos = try await sources.search(query)
                return "### search_models \(query)\n" + (repos.isEmpty ? "(no repositories found)" : repos.joined(separator: "\n"))
            case .listFiles(let repo):
                let files = try await sources.files(repo)
                listings[repo] = Dictionary(files.map { ($0.path, $0.size) }, uniquingKeysWith: { first, _ in first })
                let lines = files.map { "\($0.path) (\(Self.formatBytes($0.size)))" }
                return "### list_files \(repo)\n" + (lines.isEmpty ? "(no files)" : lines.joined(separator: "\n"))
            case .readCard(let repo):
                let card = try await sources.modelCard(repo) ?? "(no model card)"
                let clipped = card.count > Self.cardLimit ? String(card.prefix(Self.cardLimit)) + "\n…(truncated)" : card
                return "### read_card \(repo)\n\(clipped)"
            case .ggufInfo(let repo, let file):
                let metadata = try await sources.ggufMetadata(repo, file)
                let lines = metadata.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
                return "### gguf_info \(repo) \(file)\n"
                    + (lines.isEmpty ? "(no general.* metadata — typical of a diffusion model, not of a text encoder)" : lines.joined(separator: "\n"))
            case .answer:
                return ""
            }
        } catch {
            return "### \(step.toolName) failed\n\(error.localizedDescription)"
        }
    }

    // MARK: - Prompt and parsing

    static func prompt(repoID: String, denoiser: String, size: Int64, transcript: [String], isLastRound: Bool) -> String {
        """
        You are helping RxCode run a local text-to-video model with stable-diffusion.cpp (`sd-cli --mode vid_gen`).
        The user downloaded this diffusion model (the denoiser, passed with --diffusion-model):
          repo: \(repoID)
          file: \(denoiser) (\(formatBytes(size)))

        sd-cli also needs three companion files that you must find on Hugging Face:
          1. text_encoder: the LLM text encoder passed with --llm. Usually a GGUF of a language or vision-language model, often in the same repo as the denoiser. It is never the denoiser itself.
          2. video_vae: the video VAE passed with --vae.
          3. audio_vae: the audio VAE passed with --audio-vae.
        Follow the model card. Use search_models to find encoder repositories when the denoiser repository does not contain them; inspect their cards and file listings before choosing. If it pairs a text encoder quantization with this denoiser, use that one; otherwise prefer Q4_K_M or the closest mid-size quantization. If the card points to another repo for the VAEs, list that repo's files.

        Reply with exactly one JSON object and nothing else. "status" is a short present-tense note shown to the user, such as "Finding the text encoder in the model card".
        Call a tool:
          {"status": "…", "tool": "search_models", "query": "model family text encoder"}
          {"status": "…", "tool": "list_files", "repo": "owner/name"}
          {"status": "…", "tool": "read_card", "repo": "owner/name"}
          {"status": "…", "tool": "gguf_info", "repo": "owner/name", "file": "path/in/repo.gguf"}
        Or answer:
          {"status": "…", "answer": {"text_encoder": {"repo": "owner/name", "file": "path/in/repo"}, "video_vae": {"repo": "…", "file": "…"}, "audio_vae": {"repo": "…", "file": "…"}}}
        Only answer with exact paths that appeared in a list_files result.\(isLastRound ? "\nThis is your last turn: answer now." : "")

        Results so far:

        \(transcript.joined(separator: "\n\n"))
        """
    }

    /// The status note and the step in a reply, which may be wrapped in a code
    /// fence or prose.
    static func parse(_ reply: String) -> (status: String?, step: Step)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
        else { return nil }
        let status = (object["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = status?.isEmpty == false ? status : nil

        if let answer = object["answer"] as? [String: Any] {
            func companion(_ key: String) -> LocalVideoRecipe.Companion? {
                guard let entry = answer[key] as? [String: Any],
                      let repo = (entry["repo"] as? String)?.trimmingCharacters(in: .whitespaces), !repo.isEmpty,
                      let file = (entry["file"] as? String)?.trimmingCharacters(in: .whitespaces), !file.isEmpty
                else { return nil }
                return .init(repoID: repo, file: file)
            }
            guard let encoder = companion("text_encoder"), let video = companion("video_vae"),
                  let audio = companion("audio_vae") else { return nil }
            return (note, .answer(textEncoder: encoder, videoVAE: video, audioVAE: audio))
        }

        if object["tool"] as? String == "search_models" {
            guard let query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, query.count <= 200 else { return nil }
            return (note, .searchModels(query: query))
        }
        guard let tool = object["tool"] as? String,
              let repo = (object["repo"] as? String)?.trimmingCharacters(in: .whitespaces), isRepoID(repo) else { return nil }
        switch tool {
        case "list_files": return (note, .listFiles(repo: repo))
        case "read_card": return (note, .readCard(repo: repo))
        case "gguf_info":
            guard let file = (object["file"] as? String)?.trimmingCharacters(in: .whitespaces), !file.isEmpty else { return nil }
            return (note, .ggufInfo(repo: repo, file: file))
        default: return nil
        }
    }

    /// Why an answer can't be used, or nil when every file is real and fits.
    static func problem(with recipe: LocalVideoRecipe, denoiser: String, listings: [String: [String: Int64]]) -> String? {
        for (role, companion) in zip(["text_encoder", "video_vae", "audio_vae"], recipe.companions) {
            guard listings[companion.repoID]?[companion.file] != nil else {
                return "\(role) \(companion.repoID)/\(companion.file) is not a file in that repo."
            }
            let ext = (companion.file as NSString).pathExtension.lowercased()
            guard ["gguf", "safetensors"].contains(ext) else {
                return "\(role) must be a .gguf or .safetensors file."
            }
        }
        if recipe.textEncoder.localName == (denoiser as NSString).lastPathComponent {
            return "text_encoder is the denoiser itself."
        }
        if Set(recipe.companions.map(\.localName)).count < 3 {
            return "The three files must be different and have different file names."
        }
        return nil
    }

    /// `owner/name`, without path tricks.
    static func isRepoID(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != ".." && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension VideoCompanionResolver.Step {
    nonisolated var toolName: String {
        switch self {
        case .searchModels: "search_models"
        case .listFiles: "list_files"
        case .readCard: "read_card"
        case .ggufInfo: "gguf_info"
        case .answer: "answer"
        }
    }
}
