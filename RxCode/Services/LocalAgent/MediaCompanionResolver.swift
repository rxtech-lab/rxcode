import Foundation
import os

/// How to run a downloaded image or audio model: which flag loads the model,
/// the companion files it needs beside it (text encoders, VAE, vocoder or
/// audio projector), each with the engine flag that loads it, and the
/// sampling defaults its model card recommends.
nonisolated struct LocalMediaRecipe: Codable, Equatable, Sendable {
    struct Companion: Codable, Equatable, Sendable {
        /// The engine flag without dashes, e.g. `vae` or `mmproj`.
        let flag: String
        let repoID: String
        let file: String
        var localName: String { (file as NSString).lastPathComponent }
    }

    /// `diffusion-model` for a standalone denoiser, `model` for a full
    /// checkpoint or a language model.
    var mainFlag: String
    var companions: [Companion]
    var cfgScale: Double?
    var steps: Int?
    var sampler: String?
}

/// Asks the studio's setup agent which companion files a local image or
/// audio model needs, in the same read-only Hugging Face tool loop the video
/// lookup uses (`VideoCompanionResolver`). Answers are only accepted for
/// files RxCode has itself seen in a repo listing, and for engine flags on
/// the spec's allowlist, so the agent can neither invent a download nor
/// pass arbitrary flags to the engine.
nonisolated struct MediaCompanionResolver {
    /// What one kind of model may be told to load.
    struct Spec: Sendable {
        /// "text-to-image model with stable-diffusion.cpp (`sd-cli`)".
        let task: String
        /// Allowed main flags and what each means.
        let mainFlags: [String: String]
        /// Allowed companion flags and what each loads.
        let companionFlags: [String: String]
        let samplers: [String]
        /// Extra advice for the agent, such as where encoders usually live.
        let guidance: String
        /// Whether the answer may list no companions (a full checkpoint).
        let allowsNoCompanions: Bool

        static let image = Spec(
            task: "text-to-image model with stable-diffusion.cpp (`sd-cli --mode img_gen`)",
            mainFlags: [
                "diffusion-model": "a standalone diffusion model (denoiser only), such as FLUX, Z-Image, Qwen-Image or SD3 GGUFs; needs text encoders and a VAE",
                "model": "a full checkpoint that already contains its text encoder and VAE, such as most SD 1.x / SDXL files",
            ],
            companionFlags: [
                "vae": "the VAE",
                "clip_l": "the CLIP-L text encoder (FLUX, SD3)",
                "clip_g": "the CLIP-G text encoder (SD3)",
                "t5xxl": "the T5-XXL text encoder (FLUX, SD3)",
                "llm": "an LLM text encoder (Qwen-Image, Z-Image, FLUX.2)",
            ],
            samplers: ["euler", "euler_a", "heun", "dpm2", "dpm++2s_a", "dpm++2m", "dpm++2mv2", "ipndm", "lcm"],
            guidance: "Distilled or turbo models usually want cfg_scale 1.0 and few steps; classic SD wants cfg_scale around 7 and 20–30 steps. Follow the model card.",
            allowsNoCompanions: true
        )

        static let speech = Spec(
            task: "text-to-speech model with llama.cpp (`llama-tts`)",
            mainFlags: ["model": "the speech backbone GGUF"],
            companionFlags: ["mmproj": "the audio decoder / vocoder / codec GGUF that turns the backbone's tokens into a waveform, passed with -mm"],
            samplers: [],
            guidance: "Most llama.cpp speech models (OuteTTS and similar) need a separate vocoder or codec GGUF; the model card or llama.cpp's tts README names it. Answer with no companions only when the card says the backbone runs alone.",
            allowsNoCompanions: true
        )

        static let transcription = Spec(
            task: "speech recognition / audio understanding model with llama.cpp (`llama-mtmd-cli --audio`)",
            mainFlags: ["model": "the language model GGUF"],
            companionFlags: ["mmproj": "the multimodal projector GGUF with the audio encoder, passed with --mmproj"],
            samplers: [],
            guidance: "The projector usually sits in the same repo and has `mmproj` in its file name. Prefer an F16 or Q8_0 projector.",
            allowsNoCompanions: false
        )
    }

    enum Step: Equatable {
        case searchModels(query: String)
        case listFiles(repo: String)
        case readCard(repo: String)
        case ggufInfo(repo: String, file: String)
        case answer(LocalMediaRecipe)
    }

    let spec: Spec
    let taskModel: VideoCompanionResolver.TaskModel
    var sources: VideoCompanionResolver.Sources = .huggingFace
    let report: @Sendable (_ status: String, _ actor: String?) -> Void
    var maxRounds = 8
    var validationFailure: String? = nil

    private static let logger = Logger(subsystem: "com.rxlab.RxCode", category: "MediaCompanionResolver")

    func resolve(model: LocalModelInfo) async throws -> LocalMediaRecipe {
        let primary = model.files.first ?? ""
        var listings: [String: [String: Int64]] = [:]
        var transcript: [String] = []
        if let validationFailure { transcript.append("### Actual engine validation failed\n" + validationFailure + "\nRevise the recipe to fix this failure. Do not repeat the failed recipe.") }

        report("Reading \(model.repoID)…", nil)
        transcript.append(await run(.listFiles(repo: model.repoID), listings: &listings))
        transcript.append(await run(.readCard(repo: model.repoID), listings: &listings))

        for round in 0..<maxRounds {
            try Task.checkCancellation()
            let prompt = Self.prompt(spec: spec, repoID: model.repoID, file: primary, size: model.sizeBytes,
                                     transcript: transcript, isLastRound: round == maxRounds - 1)
            guard let reply = await taskModel.complete(prompt) else { throw VideoCompanionResolver.ResolveError.noReply }
            try Task.checkCancellation()
            guard let (status, step) = Self.parse(reply) else {
                Self.logger.warning("Unreadable reply: \(reply.prefix(300), privacy: .public)")
                transcript.append("### Your previous reply\nIt was not one JSON object in the required shape. Reply with JSON only.")
                continue
            }
            if let status { report(status, taskModel.label) }

            guard case .answer(let recipe) = step else {
                transcript.append(await run(step, listings: &listings))
                continue
            }
            for repo in Set(recipe.companions.map(\.repoID)) where listings[repo] == nil {
                _ = await run(.listFiles(repo: repo), listings: &listings)
            }
            if let problem = Self.problem(with: recipe, spec: spec, primary: primary, listings: listings) {
                report("Checking the answer: \(problem)", nil)
                transcript.append("### Your answer was rejected\n\(problem) Fix it and answer again.")
                continue
            }
            if recipe.companions.isEmpty {
                report("No companion files needed: \(primary) runs on its own", taskModel.label)
            }
            for companion in recipe.companions {
                let size = listings[companion.repoID]?[companion.file].map(VideoCompanionResolver.formatBytes) ?? "?"
                report("--\(companion.flag): \(companion.localName) (\(size)) from \(companion.repoID)", taskModel.label)
            }
            return recipe
        }
        throw VideoCompanionResolver.ResolveError.gaveUp
    }

    private func run(_ step: Step, listings: inout [String: [String: Int64]]) async -> String {
        do {
            switch step {
            case .searchModels(let query):
                let repos = try await sources.search(query)
                return "### search_models \(query)\n" + (repos.isEmpty ? "(no repositories found)" : repos.joined(separator: "\n"))
            case .listFiles(let repo):
                let files = try await sources.files(repo)
                listings[repo] = Dictionary(files.map { ($0.path, $0.size) }, uniquingKeysWith: { first, _ in first })
                let lines = files.map { "\($0.path) (\(VideoCompanionResolver.formatBytes($0.size)))" }
                return "### list_files \(repo)\n" + (lines.isEmpty ? "(no files)" : lines.joined(separator: "\n"))
            case .readCard(let repo):
                let card = try await sources.modelCard(repo) ?? "(no model card)"
                let limit = VideoCompanionResolver.cardLimit
                return "### read_card \(repo)\n" + (card.count > limit ? String(card.prefix(limit)) + "\n…(truncated)" : card)
            case .ggufInfo(let repo, let file):
                let metadata = try await sources.ggufMetadata(repo, file)
                let lines = metadata.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
                return "### gguf_info \(repo) \(file)\n" + (lines.isEmpty ? "(no general.* metadata)" : lines.joined(separator: "\n"))
            case .answer:
                return ""
            }
        } catch {
            return "### \(step.toolName) failed\n\(error.localizedDescription)"
        }
    }

    // MARK: - Prompt and parsing

    static func prompt(spec: Spec, repoID: String, file: String, size: Int64, transcript: [String], isLastRound: Bool) -> String {
        let mains = spec.mainFlags.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
        let flags = spec.companionFlags.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
        let samplers = spec.samplers.isEmpty ? "" : "\n\"sampler\" is optional, one of: \(spec.samplers.joined(separator: ", "))."
        return """
        You are helping RxCode run a local \(spec.task).
        The user downloaded this model:
          repo: \(repoID)
          file: \(file) (\(VideoCompanionResolver.formatBytes(size)))

        Decide how the engine loads it ("main", one of):
        \(mains)
        and which companion files it needs, each with the flag that loads it (one of):
        \(flags)
        \(spec.guidance)
        Use search_models when the repository does not contain a companion; inspect cards and file listings before choosing. Prefer Q8_0, Q4_K_M or the closest mid-size quantization when several exist.

        Reply with exactly one JSON object and nothing else. "status" is a short present-tense note shown to the user, such as "Reading the model card".
        Call a tool:
          {"status": "…", "tool": "search_models", "query": "model family vae"}
          {"status": "…", "tool": "list_files", "repo": "owner/name"}
          {"status": "…", "tool": "read_card", "repo": "owner/name"}
          {"status": "…", "tool": "gguf_info", "repo": "owner/name", "file": "path/in/repo.gguf"}
        Or answer:
          {"status": "…", "answer": {"main": "…", "companions": [{"flag": "…", "repo": "owner/name", "file": "path/in/repo"}], "cfg_scale": 1.0, "steps": 8, "sampler": "euler"}}
        "companions" may be empty only when the model needs nothing else. "cfg_scale" and "steps" are the card's recommendations; omit them when the card has none.\(samplers)
        Only answer with exact paths that appeared in a list_files result.\(isLastRound ? "\nThis is your last turn: answer now." : "")

        Results so far:

        \(transcript.joined(separator: "\n\n"))
        """
    }

    static func parse(_ reply: String) -> (status: String?, step: Step)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
        else { return nil }
        let status = (object["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = status?.isEmpty == false ? status : nil

        if let answer = object["answer"] as? [String: Any] {
            guard let main = (answer["main"] as? String)?.trimmingCharacters(in: .whitespaces), !main.isEmpty else { return nil }
            var companions: [LocalMediaRecipe.Companion] = []
            for entry in (answer["companions"] as? [[String: Any]]) ?? [] {
                guard let flag = (entry["flag"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "- ")),
                      let repo = (entry["repo"] as? String)?.trimmingCharacters(in: .whitespaces),
                      let file = (entry["file"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !flag.isEmpty, !repo.isEmpty, !file.isEmpty else { return nil }
                companions.append(.init(flag: flag, repoID: repo, file: file))
            }
            let recipe = LocalMediaRecipe(
                mainFlag: main.trimmingCharacters(in: CharacterSet(charactersIn: "-")), companions: companions,
                cfgScale: (answer["cfg_scale"] as? NSNumber)?.doubleValue,
                steps: (answer["steps"] as? NSNumber)?.intValue,
                sampler: (answer["sampler"] as? String)?.trimmingCharacters(in: .whitespaces)
            )
            return (note, .answer(recipe))
        }

        if object["tool"] as? String == "search_models" {
            guard let query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, query.count <= 200 else { return nil }
            return (note, .searchModels(query: query))
        }
        guard let tool = object["tool"] as? String,
              let repo = (object["repo"] as? String)?.trimmingCharacters(in: .whitespaces),
              VideoCompanionResolver.isRepoID(repo) else { return nil }
        switch tool {
        case "list_files": return (note, .listFiles(repo: repo))
        case "read_card": return (note, .readCard(repo: repo))
        case "gguf_info":
            guard let file = (object["file"] as? String)?.trimmingCharacters(in: .whitespaces), !file.isEmpty else { return nil }
            return (note, .ggufInfo(repo: repo, file: file))
        default: return nil
        }
    }

    /// Why an answer can't be used, or nil when every flag is allowed and
    /// every file is real.
    static func problem(with recipe: LocalMediaRecipe, spec: Spec, primary: String, listings: [String: [String: Int64]]) -> String? {
        guard spec.mainFlags[recipe.mainFlag] != nil else {
            return "main must be one of: \(spec.mainFlags.keys.sorted().joined(separator: ", "))."
        }
        if recipe.companions.isEmpty, !spec.allowsNoCompanions {
            return "This model needs at least one companion file."
        }
        for companion in recipe.companions {
            guard spec.companionFlags[companion.flag] != nil else {
                return "flag \(companion.flag) is not allowed; use one of: \(spec.companionFlags.keys.sorted().joined(separator: ", "))."
            }
            guard listings[companion.repoID]?[companion.file] != nil else {
                return "\(companion.repoID)/\(companion.file) is not a file in that repo."
            }
            let ext = (companion.file as NSString).pathExtension.lowercased()
            guard ["gguf", "safetensors"].contains(ext) else { return "\(companion.flag) must be a .gguf or .safetensors file." }
            if companion.localName == (primary as NSString).lastPathComponent {
                return "\(companion.flag) is the model file itself."
            }
        }
        if Set(recipe.companions.map(\.flag)).count < recipe.companions.count {
            return "Each flag may appear once."
        }
        if Set(recipe.companions.map(\.localName)).count < recipe.companions.count {
            return "The companion files must have different file names."
        }
        if let sampler = recipe.sampler, !sampler.isEmpty, !spec.samplers.contains(sampler) {
            return "sampler must be one of: \(spec.samplers.joined(separator: ", "))."
        }
        if let steps = recipe.steps, !(1...150).contains(steps) { return "steps must be between 1 and 150." }
        if let cfg = recipe.cfgScale, !(0...30).contains(cfg) { return "cfg_scale must be between 0 and 30." }
        return nil
    }
}

private extension MediaCompanionResolver.Step {
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
