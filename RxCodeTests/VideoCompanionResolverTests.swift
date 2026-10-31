import XCTest
@testable import RxCode

final class VideoCompanionResolverTests: XCTestCase {
    private let denoiser = LocalModelInfo(
        repoID: "unsloth/MiniMax-H3-GGUF", author: "unsloth", files: ["minimax_h3_fl2va_pruned-Q8_0.gguf"],
        sizeBytes: 1, parameterCount: nil, contextLength: nil, architecture: nil, quantization: "Q8_0", downloadedAt: Date()
    )

    private let listings: [String: [(path: String, size: Int64)]] = [
        "unsloth/MiniMax-H3-GGUF": [("minimax_h3_fl2va_pruned-Q8_0.gguf", 10), ("qwen3vl_32b_minimax_h3-Q4_K_M.gguf", 20),
                                    ("qwen3vl_32b_minimax_h3-Q2_K_M.gguf", 15), ("README.md", 1)],
        "Comfy-Org/MiniMax-H3": [("vae/minimax_h3_video_vae_fp16.safetensors", 3), ("vae/minimax_h3_audio_vae_fp32.safetensors", 2)],
    ]

    private func sources() -> VideoCompanionResolver.Sources {
        let listings = listings
        return VideoCompanionResolver.Sources(
            files: { repo in
                guard let files = listings[repo] else { throw URLError(.fileDoesNotExist) }
                return files
            },
            modelCard: { _ in "Use the Q4 text encoder. VAEs live in Comfy-Org/MiniMax-H3." },
            ggufMetadata: { _, _ in ["general.architecture": "qwen3vl"] }
        )
    }

    /// A task model that replays `replies` in order and records the prompts.
    private final class ScriptedModel: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private(set) var prompts: [String] = []
        init(_ replies: [String]) { self.replies = replies }
        func next(_ prompt: String) -> String? {
            lock.withLock {
                prompts.append(prompt)
                return replies.isEmpty ? nil : replies.removeFirst()
            }
        }
    }

    private static let answer = """
    {"status": "Picking the files", "answer": {
      "text_encoder": {"repo": "unsloth/MiniMax-H3-GGUF", "file": "qwen3vl_32b_minimax_h3-Q4_K_M.gguf"},
      "video_vae": {"repo": "Comfy-Org/MiniMax-H3", "file": "vae/minimax_h3_video_vae_fp16.safetensors"},
      "audio_vae": {"repo": "Comfy-Org/MiniMax-H3", "file": "vae/minimax_h3_audio_vae_fp32.safetensors"}}}
    """

    func testParsesToolCallsAndAnswersInsideProse() throws {
        let tool = try XCTUnwrap(VideoCompanionResolver.parse("""
        Sure:
        ```json
        {"status": "Finding the text encoder", "tool": "gguf_info", "repo": "a/b", "file": "x.gguf"}
        ```
        """))
        XCTAssertEqual(tool.status, "Finding the text encoder")
        XCTAssertEqual(tool.step, .ggufInfo(repo: "a/b", file: "x.gguf"))

        let answer = try XCTUnwrap(VideoCompanionResolver.parse(Self.answer))
        guard case .answer(let encoder, _, let audio) = answer.step else { return XCTFail("expected an answer") }
        XCTAssertEqual(encoder.localName, "qwen3vl_32b_minimax_h3-Q4_K_M.gguf")
        XCTAssertEqual(audio.localName, "minimax_h3_audio_vae_fp32.safetensors")

        XCTAssertNil(VideoCompanionResolver.parse(#"{"tool": "list_files", "repo": "../etc"}"#))
        XCTAssertNil(VideoCompanionResolver.parse(#"{"tool": "rm", "repo": "a/b"}"#))
        XCTAssertNil(VideoCompanionResolver.parse("no json here"))
    }

    func testRejectsFilesNotInTheListing() {
        var seen: [String: [String: Int64]] = [:]
        for (repo, files) in listings { seen[repo] = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) }) }
        let made = LocalVideoRecipe(
            textEncoder: .init(repoID: "unsloth/MiniMax-H3-GGUF", file: "made-up.gguf"),
            videoVAE: .init(repoID: "Comfy-Org/MiniMax-H3", file: "vae/minimax_h3_video_vae_fp16.safetensors"),
            audioVAE: .init(repoID: "Comfy-Org/MiniMax-H3", file: "vae/minimax_h3_audio_vae_fp32.safetensors")
        )
        XCTAssertNotNil(VideoCompanionResolver.problem(with: made, denoiser: denoiser.files[0], listings: seen))
        let itself = LocalVideoRecipe(
            textEncoder: .init(repoID: "unsloth/MiniMax-H3-GGUF", file: "minimax_h3_fl2va_pruned-Q8_0.gguf"),
            videoVAE: made.videoVAE, audioVAE: made.audioVAE
        )
        XCTAssertNotNil(VideoCompanionResolver.problem(with: itself, denoiser: denoiser.files[0], listings: seen))
    }

    func testResolvesThroughToolsAndRetriesARejectedAnswer() async throws {
        let wrong = Self.answer.replacingOccurrences(of: "qwen3vl_32b_minimax_h3-Q4_K_M.gguf", with: "encoder.gguf")
        let model = ScriptedModel([
            #"{"status": "Finding the text encoder", "tool": "gguf_info", "repo": "unsloth/MiniMax-H3-GGUF", "file": "qwen3vl_32b_minimax_h3-Q4_K_M.gguf"}"#,
            #"{"status": "Listing the VAE repo", "tool": "list_files", "repo": "Comfy-Org/MiniMax-H3"}"#,
            wrong,
            Self.answer,
        ])
        let reports = ScriptedModel([])
        var resolver = VideoCompanionResolver(
            taskModel: .init(label: "Haiku") { model.next($0) },
            report: { status, actor in _ = reports.next("\(actor ?? "-")|\(status)") }
        )
        resolver.sources = sources()
        let recipe = try await resolver.resolve(model: denoiser)

        XCTAssertEqual(recipe.textEncoder, .init(repoID: "unsloth/MiniMax-H3-GGUF", file: "qwen3vl_32b_minimax_h3-Q4_K_M.gguf"))
        XCTAssertEqual(recipe.videoVAE.repoID, "Comfy-Org/MiniMax-H3")
        XCTAssertEqual(model.prompts.count, 4)
        // Tool results and the rejection reach the model on later rounds.
        XCTAssertTrue(model.prompts[1].contains("general.architecture = qwen3vl"))
        XCTAssertTrue(model.prompts[3].contains("Your answer was rejected"))
        // The task model's notes are reported under its label.
        XCTAssertTrue(reports.prompts.contains("Haiku|Finding the text encoder"))
        XCTAssertTrue(reports.prompts.contains { $0.hasPrefix("Haiku|Text encoder: qwen3vl_32b_minimax_h3-Q4_K_M.gguf") })
    }

    func testSearchesForCompanionsOutsideTheDenoiserRepository() async throws {
        let scripted = ScriptedModel([
            #"{"tool":"search_models","query":"H3 text encoder"}"#,
            Self.answer,
        ])
        var resolver = VideoCompanionResolver(taskModel: .init(label: "Task model") { scripted.next($0) }, report: { _, _ in })
        resolver.sources = sources()
        resolver.sources.search = { query in
            XCTAssertEqual(query, "H3 text encoder")
            return ["unsloth/MiniMax-H3-GGUF"]
        }
        _ = try await resolver.resolve(model: denoiser)
        XCTAssertTrue(scripted.prompts[1].contains("### search_models H3 text encoder\nunsloth/MiniMax-H3-GGUF"))
        XCTAssertNil(VideoCompanionResolver.parse(#"{"tool":"search_models","query":" "}"#))
    }

    func testGivesUpWhenTheModelStopsReplying() async {
        var resolver = VideoCompanionResolver(taskModel: .init(label: "Haiku") { _ in nil }, report: { _, _ in })
        resolver.sources = sources()
        do {
            _ = try await resolver.resolve(model: denoiser)
            XCTFail("expected a failure")
        } catch {}
    }

    func testReadsGeneralMetadataFromTruncatedGGUFHeader() {
        var data = Data("GGUF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendString(_ value: String) { append(UInt64(value.utf8.count)); data.append(contentsOf: value.utf8) }
        append(UInt32(3)); append(UInt64(0)); append(UInt64(4))
        appendString("general.architecture"); append(UInt32(8)); appendString("qwen3vl")
        appendString("qwen3vl.context_length"); append(UInt32(4)); append(UInt32(32_768))
        appendString("general.file_type"); append(UInt32(4)); append(UInt32(15))
        // A tokenizer array cut off by the range request.
        appendString("tokenizer.ggml.tokens"); append(UInt32(9)); append(UInt32(8)); append(UInt64(1_000))

        let metadata = GGUFHeader.generalMetadata(in: data)
        XCTAssertEqual(metadata["general.architecture"], "qwen3vl")
        XCTAssertEqual(metadata["general.file_type"], "15")
        XCTAssertNil(metadata["qwen3vl.context_length"])
        XCTAssertTrue(GGUFHeader.generalMetadata(in: Data("nope".utf8)).isEmpty)
    }
}
