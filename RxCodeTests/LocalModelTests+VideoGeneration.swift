import XCTest
import ImageIO
import AVFoundation
import os
import RxAgentCore
import RxAgentHarness
import struct RxCodeCore.VideoGenerationSettings
@testable import RxCode

extension LocalModelTests {
    func testVideoRecipeMatchesMiniMaxDenoisersOnly() throws {
        func model(_ repo: String, _ file: String) -> LocalModelInfo {
            LocalModelInfo(repoID: repo, author: "unsloth", files: [file], sizeBytes: 1, parameterCount: nil,
                           contextLength: nil, architecture: nil, quantization: nil, downloadedAt: Date())
        }
        XCTAssertTrue(LocalVideoRecipe.supports(model("unsloth/MiniMax-H3-GGUF", "minimax_h3_ref2va_pruned-Q2_K.gguf")))
        XCTAssertTrue(LocalVideoRecipe.supports(model("joeygambino/MiniMax-H3-x-Z-Image-GGUF", "MiniMax-H3-fl2va-zs05-Q4_0.gguf")))
        XCTAssertFalse(LocalVideoRecipe.supports(model("unsloth/MiniMax-H3-GGUF", "qwen3vl_32b_minimax_h3-Q2_K_M.gguf")))
        XCTAssertFalse(LocalVideoRecipe.supports(model("Qwen/Qwen3-8B-GGUF", "Qwen3-8B-Q4_K_M.gguf")))
        let small = LocalVideoRecipe(
            textEncoder: .init(repoID: "test/encoder", file: "encoder.gguf"),
            videoVAE: .init(repoID: "test/vae", file: "video.safetensors"),
            audioVAE: .init(repoID: "test/vae", file: "audio.safetensors")
        )
        let directory = URL(filePath: "/models/h3")
        let arguments = small.arguments(denoiser: directory.appending(path: "d.gguf"), directory: directory,
                                        prompt: "a fox", output: URL(filePath: "/out/a.webm"))
        for (flag, value) in [("--mode", "vid_gen"), ("--cfg-scale", "1.0"), ("--backend", "te=cpu"),
                              ("--llm", "/models/h3/encoder.gguf"),
                              ("--audio-vae", "/models/h3/audio.safetensors"),
                              ("--prompt", "a fox"), ("--seed", "-1"), ("--output", "/out/a.webm")] {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag), flag)
            XCTAssertEqual(arguments[index + 1], value, flag)
        }
    }

    func testVideoRecipeUsesSelectedQualitySettings() throws {
        let recipe = LocalVideoRecipe(
            textEncoder: .init(repoID: "test", file: "encoder.gguf"),
            videoVAE: .init(repoID: "test", file: "video.safetensors"),
            audioVAE: .init(repoID: "test", file: "audio.safetensors")
        )
        var settings = VideoGenerationSettings()
        settings.select(.high)
        settings.frames = 49
        settings.fps = 30
        settings.seed = 123
        let arguments = recipe.arguments(denoiser: URL(filePath: "/d.gguf"),
            directory: URL(filePath: "/models"), prompt: "snowman", output: URL(filePath: "/a.avi"),
            settings: settings)
        for (flag, value) in [("--width", "1280"), ("--height", "768"), ("--steps", "24"),
                              ("--video-frames", "49"), ("--fps", "30"), ("--seed", "123")] {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag))
            XCTAssertEqual(arguments[index + 1], value)
        }
    }

    func testVideoFileNamesAndProgressParsing() {
        let date = Date(timeIntervalSince1970: 0)
        let name = LocalVideoHarnessModel.fileName(for: "A red panda, stepping along a log!", date: date)
        XCTAssertTrue(name.hasSuffix("-a-red-panda-stepping.mp4"), name)
        XCTAssertTrue(LocalVideoHarnessModel.fileName(for: "!!!", date: date).hasSuffix("-video.mp4"))

        XCTAssertEqual(StableDiffusionProcess.ProgressReader.step(in: "  |=====>     | 3/4 - 12.34s/it"), "Step 3/4 · 12.34s/it")
        XCTAssertNil(StableDiffusionProcess.ProgressReader.step(in: "[INFO ] loading diffusion model"))

        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let reader = StableDiffusionProcess.ProgressReader { line in lines.withLock { $0.append(line) } }
        // Redraws arrive split across reads and joined by carriage returns.
        reader.consume(Data("|==  | 1/4 - 9.0s/it\r|=== | 1/4 - 9.0s/i".utf8))
        reader.consume(Data("t\r|====| 2/4 - 8.5s/it\n".utf8))
        XCTAssertEqual(lines.withLock { $0 }, ["Step 1/4 · 9.0s/it", "Step 2/4 · 8.5s/it"])

        XCTAssertTrue(GeneratedVideoSheet.canPlay(path: "/tmp/My Clip.mp4"))
        XCTAssertFalse(GeneratedVideoSheet.canPlay(path: "/tmp/notes.md"))
    }

    func testMLXMediaProgressParsing() {
        let parse: (String) -> String? = { StableDiffusionProcess.ProgressReader.step(in: $0) }
        XCTAssertEqual(parse("Generating:  25%|██      | 2/8 [00:04<00:12, 2.00s/it]"), "Step 2/8")
        XCTAssertEqual(parse("\u{001B}[32m100%|████| 8/8 [00:16<00:00, 2.00s/it]\u{001B}[0m"), "Step 8/8")
        XCTAssertEqual(parse("0%|          | 0/8 [00:00<?, ?it/s]"), "Step 0/8")
        XCTAssertEqual(StableDiffusionProcess.ProgressReader.step(in: "Segment 1/2: 25%|xx| 2/8 [00:04<00:12, 2.00tokens/s]", reportsTotal: false), "Processed 2 generation steps")
        XCTAssertNil(parse("model/revision 2/8"))
        XCTAssertNil(parse("0%| | 0/0 [00:00<?, ?it/s]"))
        XCTAssertEqual(parse("Joining 3 audio files"), "Joining 3 audio files")
        XCTAssertEqual(parse("✅ Audio successfully generated and saving as: /tmp/a.wav"), "Saving audio…")
        XCTAssertEqual(parse("Duration:              00:00:03.2"), "Generated audio · 00:00:03.2")
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let reader = StableDiffusionProcess.ProgressReader { line in lines.withLock { $0.append(line) } }
        reader.consume(Data("25%|xx| 2/8 [00:04<00:12, 2.00s/it]\r50%|xxxx| 4/".utf8))
        reader.consume(Data("8 [00:08<00:08, 2.00s/it]\r50%|xxxx| 4/8 [00:08<00:08, 2.00s/it]\n".utf8))
        XCTAssertEqual(lines.withLock { $0 }, ["Step 2/8", "Step 4/8"])
    }

    func testVideoModelTurnsAMessageIntoOneToolCall() throws {
        let request = HarnessModelRequest(model: "m", system: "", messages: [.user("  a fox in snow  ")])
        let chunks = LocalVideoHarnessModel.reply(to: request, modelID: "unsloth/MiniMax-H3-GGUF/x.gguf")
        guard case .toolCall(let call) = chunks.first else { return XCTFail("\(chunks)") }
        XCTAssertEqual(call.name, "VideoGeneration")
        let arguments = try XCTUnwrap(call.arguments?.objectValue)
        XCTAssertEqual(arguments["prompt"], .string("a fox in snow"))
        XCTAssertEqual(arguments["model"], .string("unsloth/MiniMax-H3-GGUF/x.gguf"))
        XCTAssertEqual(chunks.last, .finished(reason: "tool_calls"))

        // The tool's result ends the turn; one-off generation prompts never render.
        let finished = HarnessModelRequest(model: "m", system: "", messages: [
            .user("a fox"), .assistant("", toolCalls: [call]),
            .toolResult(callID: call.id, name: call.name, text: "{}"),
        ])
        XCTAssertEqual(LocalVideoHarnessModel.reply(to: finished, modelID: "m"), [.finished(reason: "stop")])
        var summary = request
        summary.mode = .generation
        XCTAssertEqual(LocalVideoHarnessModel.reply(to: summary, modelID: "m"), [.finished(reason: "stop")])
    }

    func testChatModelsNeverSeeTheVideoTool() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = HarnessModelRequest(model: "m", system: "", messages: [.user("hi")])
        request.tools = [
            HarnessToolSpec(name: "read", description: "Read a file", parameters: .object([:])),
            HarnessToolSpec(name: "VideoGeneration", description: "Video", parameters: .object([:])),
        ]
        let compacted = try LocalModelContext.compact(request, directory: directory)
        XCTAssertEqual(compacted.tools.map(\.name), ["read"])
        XCTAssertFalse(compacted.system.contains("VideoGeneration"))
    }

    func testVideoToolResultsDecodeInTheChatCard() throws {
        let result = VideoGenerationResult(savedPath: "/v/a b.mp4", prompt: "fox", model: "H3", elapsedSeconds: 96, width: 640, height: 384)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["savedPath"] as? String, "/v/a b.mp4")
        XCTAssertEqual(decoded["elapsedSeconds"] as? Int, 96)
        XCTAssertEqual(decoded["width"] as? Int, 640)
        let failure = VideoGenerationTool.failure("Out of memory")
        XCTAssertTrue(failure.isError)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(failure.text.utf8))["displayError"], "Out of memory")
    }

    func testAVIFromStableDiffusionConvertsToPlayableMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A 64×32 red JPEG frame.
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        // sd-cli's layout: hdrl with a video and an audio strl, then movi.
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func chunk(_ id: String, _ body: Data) -> Data {
            Data(id.utf8) + le32(body.count) + body + (body.count % 2 == 1 ? Data([0]) : Data())
        }
        func list(_ type: String, _ body: Data) -> Data { chunk("LIST", Data(type.utf8) + body) }
        func strh(_ type: String, scale: Int, rate: Int) -> Data {
            chunk("strh", Data(type.utf8) + Data(count: 16) + le32(scale) + le32(rate) + Data(count: 24))
        }
        let videoFormat = chunk("strf", le32(40) + le32(64) + le32(32) + Data(count: 28))
        let audioFormat = chunk("strf", le16(1) + le16(2) + le32(32_000) + le32(128_000) + le16(4) + le16(16))
        let hdrl = list("hdrl", chunk("avih", Data(count: 56))
            + list("strl", strh("vids", scale: 1, rate: 24) + videoFormat)
            + list("strl", strh("auds", scale: 1, rate: 32_000) + audioFormat))
        var movi = Data()
        for _ in 0..<12 { movi += chunk("00dc", jpeg as Data) }
        movi += chunk("01wb", Data(count: 32_000 / 2 * 4)) // half a second of silence
        let body = Data("AVI ".utf8) + hdrl + list("movi", movi)
        let avi = directory.appending(path: "clip.avi")
        try (Data("RIFF".utf8) + le32(body.count) + body).write(to: avi)

        let parsed = try AVIToMP4Converter.parse(Data(contentsOf: avi))
        XCTAssertEqual(parsed.jpegFrames.count, 12)
        XCTAssertEqual(parsed.framesPerSecond, 24)
        XCTAssertEqual(parsed.audio, .init(sampleRate: 32_000, channels: 2, bitsPerSample: 16))

        let mp4 = directory.appending(path: "clip.mp4")
        try await AVIToMP4Converter.convert(avi: avi, to: mp4)
        let asset = AVURLAsset(url: mp4)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let kinds = try await asset.load(.tracks).map(\.mediaType)
        XCTAssertEqual(Set(kinds), [.video, .audio])
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 0.5, accuracy: 0.05)
        XCTAssertThrowsError(try AVIToMP4Converter.parse(Data("not a video".utf8)))
    }
}
