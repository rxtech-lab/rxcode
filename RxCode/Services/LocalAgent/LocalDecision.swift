import Foundation
import RxAgentCore
import RxAgentHarness
import struct RxCodeCore.DecisionRequest
import struct RxCodeCore.DecisionResult
import struct RxCodeCore.DecisionSettings
import enum RxCodeCore.VideoGenerationProgress

/// The verdict readout of a Jev-Style decision model (`readout_config.json`,
/// format `macjev-readout-v1`), or the uncalibrated default other
/// text-classification GGUFs are judged with.
///
/// Input layout (`macjev-render-v1`; segments are tokenized separately and
/// concatenated):
///
///     State:\n<state>\n\n
///     Question [<type>]: <question>\nOptions:\n
///     - <option 1>\n … - <option K>\n
///     Judge each option:\n
///     <option 1> ->\n … <option K> ->\n
///
/// An option's score is logit(" yes") − logit(" no") at its ` ->` slot;
/// probabilities are softmax(scores / T).
nonisolated struct DecisionReadout: Equatable, Sendable {
    var yesText = " yes"
    var noText = " no"
    var slotText = " ->"
    /// Token ids the config pins; checked against the tokenizer before use.
    var yesID: Int?
    var noID: Int?
    var slotID: Int?
    var temperature = 1.0
    var isCalibrated = false

    static let configFile = "readout_config.json"

    /// Reads a `macjev-readout-v1` config; nil for any other format.
    static func parse(_ data: Data) -> DecisionReadout? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == "macjev-readout-v1", object["readout"] as? String == "verdict",
              let slots = object["slot_tokens"] as? [String: Any] else { return nil }
        func token(_ key: String) -> (String, Int)? {
            guard let entry = slots[key] as? [String: Any], let text = entry["text"] as? String,
                  let id = (entry["id"] as? NSNumber)?.intValue else { return nil }
            return (text, id)
        }
        guard let yes = token("yes"), let no = token("no"), let slot = token("verdict_slot") else { return nil }
        let temperatures = object["temperatures"] as? [String: Any]
        var global = (temperatures?["global"] as? NSNumber)?.doubleValue ?? 1
        if let clamp = temperatures?["clamp"] as? [NSNumber], clamp.count == 2 {
            global = min(clamp[1].doubleValue, max(clamp[0].doubleValue, global))
        }
        return DecisionReadout(yesText: yes.0, noText: no.0, slotText: slot.0, yesID: yes.1, noID: no.1,
                               slotID: slot.1, temperature: global, isCalibrated: true)
    }

    /// The option lines the model reads: `name: detail`, or the fixed
    /// outcomes of a true/false statement.
    static func renderedOptions(_ request: DecisionRequest) -> [String] {
        if request.isStatement {
            return ["false: no, the statement does not hold", "true: yes, the statement holds"]
        }
        return request.options.map { $0.detail.isEmpty ? $0.name : "\($0.name): \($0.detail)" }
    }

    static func questionType(_ request: DecisionRequest) -> String { request.isStatement ? "noul" : "choice" }

    /// Calibrated probabilities from raw scores.
    func probabilities(_ scores: [Double]) -> [Double] {
        guard let top = scores.max() else { return [] }
        let t = max(temperature, 0.05)
        let weights = scores.map { exp(($0 - top) / t) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }
}

/// Scores a decision against a running `llama-server`: tokenizes the
/// rendered segments with `/tokenize`, then reads the next-token logprobs at
/// each option's slot with `/completion`. Each prompt is a prefix of the next,
/// so the server's prompt cache makes the extra requests cheap.
nonisolated struct DecisionScorer {
    enum ScoreError: LocalizedError {
        case tokenizer(String)
        case http(Int)
        case malformed
        case tooLong(Int, Int)

        var errorDescription: String? {
            switch self {
            case .tokenizer(let text): "This model's tokenizer splits \"\(text)\" into several tokens, so it can't be read as a decision model."
            case .http(let status): "The local model server returned HTTP \(status)."
            case .malformed: "The local model server returned an unexpected response."
            case .tooLong(let needed, let limit): "The question and options need \(needed) tokens, more than the \(limit) the model accepts. Shorten them."
            }
        }
    }

    let baseURL: URL
    let readout: DecisionReadout
    let contextSize: Int
    var session: URLSession = .shared
    var nativeTokenize: (@Sendable (String) async throws -> [Int])? = nil
    var nativeLogits: (@Sendable ([Int]) async throws -> [Int: Double])? = nil

    /// Raw scores, one per rendered option. `state` is trimmed from the end
    /// when the input would not fit the context.
    func scores(state: String, request: DecisionRequest) async throws -> [Double] {
        let yes = try await singleToken(readout.yesText, expected: readout.yesID)
        let no = try await singleToken(readout.noText, expected: readout.noID)
        let slot = try await singleToken(readout.slotText, expected: readout.slotID)

        let options = DecisionReadout.renderedOptions(request)
        var head = try await tokenize("Question [\(DecisionReadout.questionType(request))]: \(request.question)\n\(DecisionRequest.optionsHeader)\n")
        let dash = try await tokenize("- ")
        let newline = try await tokenize("\n")
        var encoded: [[Int]] = []
        for option in options { encoded.append(try await tokenize(option)) }
        for option in encoded { head += dash + option + newline }
        head += try await tokenize("Judge each option:\n")
        var relativeSlots: [Int] = []
        for option in encoded {
            head += option + [slot]
            relativeSlots.append(head.count - 1)
            head += newline
        }

        let opening = try await tokenize("State:\n")
        let closing = try await tokenize("\n\n")
        // Room for one sampled token beside the prompt.
        let budget = contextSize - 8 - head.count - opening.count - closing.count
        guard budget > 16 else { throw ScoreError.tooLong(head.count, contextSize) }
        var stateTokens = try await tokenize(state)
        if stateTokens.count > budget { stateTokens = Array(stateTokens.prefix(budget)) }
        let prefix = opening + stateTokens + closing
        let ids = prefix + head

        var scores: [Double] = []
        for relative in relativeSlots {
            try Task.checkCancellation()
            let logprobs = try await nextTokenLogprobs(Array(ids[...(prefix.count + relative)]))
            // A token missing from the top list is less likely than any listed one.
            let floor = (logprobs.values.min() ?? -30) - 1
            scores.append((logprobs[yes] ?? floor) - (logprobs[no] ?? floor))
        }
        return scores
    }

    private func singleToken(_ text: String, expected: Int?) async throws -> Int {
        let tokens = try await tokenize(text)
        guard tokens.count == 1, expected == nil || tokens[0] == expected else { throw ScoreError.tokenizer(text) }
        return tokens[0]
    }

    /// User text is tokenized with special tokens disabled, so `<|im_end|>`
    /// in a web snippet can never act as a control token.
    func tokenize(_ text: String) async throws -> [Int] {
        guard !text.isEmpty else { return [] }
        if let nativeTokenize { return try await nativeTokenize(text) }
        let json = try await post("tokenize", ["content": text, "add_special": false, "parse_special": false])
        guard let tokens = json["tokens"] as? [NSNumber] else { throw ScoreError.malformed }
        return tokens.map(\.intValue)
    }

    func nextTokenLogprobs(_ prompt: [Int]) async throws -> [Int: Double] {
        if let nativeLogits { return try await nativeLogits(prompt) }
        let json = try await post("completion", [
            "prompt": prompt, "n_predict": 1, "n_probs": 100, "cache_prompt": true,
            "temperature": 0, "post_sampling_probs": false,
        ])
        guard let first = (json["completion_probabilities"] as? [[String: Any]])?.first,
              let top = first["top_logprobs"] as? [[String: Any]] else { throw ScoreError.malformed }
        var result: [Int: Double] = [:]
        for entry in top {
            if let id = (entry["id"] as? NSNumber)?.intValue, let logprob = (entry["logprob"] as? NSNumber)?.doubleValue {
                result[id] = logprob
            }
        }
        return result
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ScoreError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ScoreError.malformed }
        return json
    }
}

/// Judges the user's question with a local decision model, optionally with
/// web search results as the state it reads.
///
/// Registered with the local harness; chat models never see it (see
/// `LocalModelContext.compact`).
nonisolated struct DecisionTool: HarnessTool {
    struct Job: Sendable {
        let model: LocalModelInfo
        /// Installs llama.cpp and the readout config if missing, starts the
        /// model's server; returns where to score and how to read it.
        let prepare: @Sendable (_ status: @escaping @Sendable (String) -> Void) async throws
            -> (baseURL: URL, contextSize: Int, readout: DecisionReadout)
        var nativeScores: (@Sendable (String, DecisionRequest, @escaping @Sendable (String) -> Void) async throws -> ([Double], DecisionReadout))? = nil
    }

    let job: @Sendable (_ modelID: String) async -> Job?
    var search: @Sendable (_ query: String, _ limit: Int) async throws -> [DecisionResult.Source] = {
        try await WebSearchClient.search($0, limit: $1)
    }

    var name: String { "Decision" }
    var description: String { "Judges a question against fixed options with the selected local decision model, optionally using web search results." }
    var parameters: RxAgentCore.JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string"), "description": .string("The question and its options.")]),
                "model": .object(["type": .string("string"), "description": .string("The local decision model id.")]),
            ]),
            "required": .array([.string("prompt"), .string("model")]),
        ])
    }
    var isReadOnly: Bool { true }

    func execute(_ input: RxAgentCore.JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        let settings = DecisionSettings.load()
        let callID = context.callID
        let status: @Sendable (String) -> Void = { VideoGenerationProgress.post(callID: callID, status: $0) }
        guard case .object(let fields) = input, case .string(let text)? = fields["prompt"],
              case .string(let modelID)? = fields["model"], let job = await job(modelID) else {
            return LocalStudioTools.failure("The selected model can't make decisions.", title: "Decision failed")
        }
        let prompt = LocalStudioPrompt(text)
        let request = DecisionRequest.parse(prompt.text)
        guard !request.question.isEmpty else {
            return LocalStudioTools.failure("Ask a question or state something to judge.", title: "Decision failed")
        }
        do {
            let started = Date()
            var sources: [DecisionResult.Source] = []
            if settings.searchWeb {
                status("Searching the web…")
                do {
                    sources = try await search(request.question, settings.maxSources)
                    status(sources.isEmpty ? "No web results; judging without them" : "Read \(sources.count) web results")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    status("Web search failed: \(error.localizedDescription)")
                }
            }
            status("Judging \(DecisionReadout.renderedOptions(request).count) options…")
            let state = Self.state(question: request.question, context: prompt.pastedTexts, sources: sources)
            let scores: [Double]
            let readout: DecisionReadout
            if let nativeScores = job.nativeScores {
                (scores, readout) = try await nativeScores(state, request, status)
            } else {
                let prepared = try await job.prepare(status)
                readout = prepared.readout
                scores = try await DecisionScorer(baseURL: prepared.baseURL, readout: readout,
                                                 contextSize: prepared.contextSize).scores(state: state, request: request)
            }
            let probabilities = readout.probabilities(scores)
            let names = request.isStatement ? ["False", "True"] : request.options.map(\.name)
            let details = request.isStatement ? ["The statement does not hold", "The statement holds"] : request.options.map(\.detail)
            let ranked = zip(names.indices, probabilities).max { $0.1 < $1.1 }
            let result = DecisionResult(
                question: request.question, type: request.isStatement ? "statement" : "choice",
                scores: names.indices.map { DecisionResult.Score(name: names[$0], detail: details[$0], probability: probabilities[$0], score: scores[$0]) },
                answer: ranked.map { names[$0.0] } ?? "",
                sources: sources, model: job.model.displayName,
                elapsedSeconds: Int(Date().timeIntervalSince(started)),
                calibration: readout.isCalibrated ? "Calibrated" : "Uncalibrated"
            )
            return HarnessToolOutput(text: result.json, title: "Decision")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return LocalStudioTools.failure(error.localizedDescription, title: "Decision failed")
        }
    }

    /// What the model reads before the question: pasted context, then the
    /// web results. With neither, the question itself.
    static func state(question: String, context: [String], sources: [DecisionResult.Source]) -> String {
        var parts = context.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !sources.isEmpty {
            let lines = sources.enumerated().map { index, source in
                "\(index + 1). \(source.title)\n\(source.snippet)\n\(source.url)"
            }
            parts.append("Web search results for \"\(question)\":\n" + lines.joined(separator: "\n\n"))
        }
        return parts.isEmpty ? question : parts.joined(separator: "\n\n")
    }
}
