import XCTest
import CoreGraphics
import ImageIO
import struct RxCodeCore.ImageGenerationSettings
@testable import RxCode

final class ImageEngineValidationTests: XCTestCase {
    func testInstalledQwenEngineValidationAndGeneration() async throws {
        guard ProcessInfo.processInfo.environment["RXCODE_TEST_MFLUX"] == "1" else {
            throw XCTSkip("Set RXCODE_TEST_MFLUX=1 to run the installed Qwen model on Metal.")
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/RxCode")
        let models = support.appending(path: "LocalModels")
        var model = LocalModelInfo(repoID: "mflux-community/qwen-image-2-1-turbo-mflux-q4", author: "mflux-community",
            files: ["model_index.json"], sizeBytes: 1, parameterCount: nil, contextLength: nil,
            architecture: nil, quantization: nil, downloadedAt: Date())
        model.format = .mlx
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.directory(in: models).path))
        let output = FileManager.default.temporaryDirectory.appending(path: "rxcode-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let job = ImageGenerationTool.Job(model: model, modelsRoot: models, outputDirectory: output,
            prepare: { _ in throw MLXStudioMedia.Failure("The MLX path must not use GGUF setup") })
        _ = try await MLXStudioMedia.image(job: job, prompt: LocalStudioPrompt(ImageEngineValidation.prompt),
            settings: ImageEngineValidation.settings, status: { print($0) })
        let images = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(images.count, 1, "The setup test must not appear in generated output")
        try ImageEngineValidation.checkImage(at: XCTUnwrap(images.first))
    }

    private func writeImage(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testRepairsFailedCandidateAndDeletesTestArtifacts() async throws {
        var tested: [Int] = []
        var paths: [URL] = []
        let result = try await ImageEngineValidation.run(initial: 0, test: { candidate, output in
            tested.append(candidate)
            paths.append(output)
            if candidate == 0 { throw MLXStudioMedia.Failure("missing tokenizer") }
            try self.writeImage(output)
        }, repair: { candidate, error in
            XCTAssertTrue(error.contains("missing tokenizer"))
            return candidate + 1
        }, status: { _ in })
        XCTAssertEqual(result, 1)
        XCTAssertEqual(tested, [0, 1])
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) })
    }

    func testSuccessfulExitWithoutImageNeverPassesAndStopsAfterTwoRepairs() async {
        var attempts = 0
        var repairs = 0
        do {
            _ = try await ImageEngineValidation.run(initial: 0, test: { _, _ in
                attempts += 1
            }, repair: { candidate, error in
                repairs += 1
                XCTAssertTrue(error.contains("decodable"))
                return candidate + 1
            }, status: { _ in })
            XCTFail("An exit code without an image must not establish readiness")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("after 3 attempts"))
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(repairs, 2)
    }

    func testCancellationDoesNotAskAgentForRepair() async {
        var repairs = 0
        do {
            _ = try await ImageEngineValidation.run(initial: 0, test: { _, _ in
                throw CancellationError()
            }, repair: { _, _ in
                repairs += 1
                return 1
            }, status: { _ in })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(repairs, 0)
    }

    func testCorruptImageIsRejectedWithoutAnAgent() async throws {
        do {
            _ = try await ImageEngineValidation.run(initial: 0, test: { _, output in
                try Data("not an image".utf8).write(to: output)
            }, repair: { _, _ in nil }, status: { _ in })
            XCTFail("Corrupt output must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("decodable"))
        }
    }

    func testSessionReusesDecidedPipelineAndReconfiguresOnlyAfterAnError() async throws {
        let key = ImagePipelineMemory.key(session: UUID().uuidString, model: "test/model")
        var configured: [String?] = []
        var failNext = false
        let configure: ((config: Int, error: String)?) async throws -> Int = { failure in
            configured.append(failure?.error)
            return (failure?.config ?? 0) + 1
        }
        let generate: (Int) async throws -> Int = { config in
            if failNext { failNext = false; throw MLXStudioMedia.Failure("engine broke") }
            return config
        }
        let first = try await ImageEngineValidation.remembered(key: key, configure: configure, generate: generate, status: { _ in })
        let second = try await ImageEngineValidation.remembered(key: key, configure: configure, generate: generate, status: { _ in })
        XCTAssertEqual([first, second], [1, 1])
        XCTAssertEqual(configured, [nil], "A decided pipeline must not ask the setup agent again")

        failNext = true
        let repaired = try await ImageEngineValidation.remembered(key: key, configure: configure, generate: generate, status: { _ in })
        XCTAssertEqual(repaired, 2)
        XCTAssertEqual(configured, [nil, "engine broke"])
        let reused = try await ImageEngineValidation.remembered(key: key, configure: configure, generate: generate, status: { _ in })
        XCTAssertEqual(reused, 2)
        XCTAssertEqual(configured.count, 2)

        let otherSession = ImagePipelineMemory.key(session: UUID().uuidString, model: "test/model")
        _ = try await ImageEngineValidation.remembered(key: otherSession, configure: configure, generate: generate, status: { _ in })
        XCTAssertEqual(configured.count, 3, "Each session decides its own pipeline")
    }

    func testPipelineSelectionValidatesCapabilitiesAndSourceRequirements() throws {
        for base in ["schnell", "dev", "z-image-turbo", "qwen-image", "qwen-image-2.1", "qwen-image-2.1-turbo"] {
            for pipeline in ["text_to_image", "image_to_image", "instruction_edit"] {
                let strength = pipeline == "instruction_edit" ? ",\"strength\":1" : ""
                let reply = "{\"base_model\":\"\(base)\",\"pipeline\":\"\(pipeline)\"\(strength)}"
                let supported = pipeline != "instruction_edit" || base.hasPrefix("qwen-image-2.1")
                XCTAssertEqual(MLXStudioMedia.imagePlan(reply: reply, hasSource: true) != nil, supported)
                XCTAssertEqual(MLXStudioMedia.imagePlan(reply: reply, hasSource: false) != nil, pipeline == "text_to_image")
            }
        }
        for reply in [#"{"base_model":"arbitrary","pipeline":"text_to_image"}"#,
                      #"{"base_model":"dev","pipeline":"shell"}"#,
                      #"{"base_model":"dev","pipeline":"text_to_image","command":"arbitrary"}"#,
                      #"{"unsupported":"missing files"}"#,
                      #"{"base_model":"qwen-image-2.1","pipeline":"instruction_edit"}"#,
                      #"{"base_model":"qwen-image-2.1","pipeline":"instruction_edit","strength":0}"#,
                      #"{"base_model":"qwen-image-2.1","pipeline":"instruction_edit","strength":1.5}"#,
                      #"{"base_model":"qwen-image-2.1","pipeline":"instruction_edit","strength":"1"}"#,
                      #"{"base_model":"qwen-image-2.1","pipeline":"image_to_image","strength":0.5}"#] {
            XCTAssertNil(MLXStudioMedia.imagePlan(reply: reply, hasSource: true), reply)
        }
        let subtle = MLXStudioMedia.imagePlan(reply: #"{"base_model":"qwen-image-2.1-turbo","pipeline":"instruction_edit","strength":0.9}"#,
                                              hasSource: true)
        XCTAssertEqual(subtle?.strength, 0.9)
        XCTAssertEqual(MLXStudioMedia.editStrength(reply: #"{"strength":0.85}"#), 0.85)
        XCTAssertNil(MLXStudioMedia.editStrength(reply: #"{"strength":true}"#))
        XCTAssertNil(MLXStudioMedia.editStrength(reply: #"{"strength":1,"command":"x"}"#))
    }

    func testTaskAgentChoosesPipelineBeforeGenerationAndCanChangeItForRepair() async throws {
        let model = LocalModelInfo(repoID: "test/Qwen-Image-2.1", author: "test", files: [],
            sizeBytes: 0, parameterCount: nil, contextLength: nil, architecture: nil,
            quantization: nil, downloadedAt: Date())
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let job = ImageGenerationTool.Job(taskModel: .init(label: "Test setup agent", complete: { request in
            XCTAssertTrue(request.contains("cartoon style"))
            if request.contains("Choose the edit strength") { return #"{"strength":0.9}"# }
            XCTAssertTrue(request.contains("Source available: true"))
            if request.contains("test edit failure") {
                return #"{"base_model":"qwen-image-2.1","pipeline":"image_to_image"}"#
            }
            return #"{"base_model":"qwen-image-2.1","pipeline":"instruction_edit","strength":1}"#
        }), model: model, modelsRoot: root, outputDirectory: root,
            prepare: { _ in throw MLXStudioMedia.Failure("Unused") })
        let prompt = LocalStudioPrompt("cartoon style\n[Attached image: /tmp/source.png]")
        let plan = try await MLXStudioMedia.selectImagePlan(job: job, prompt: prompt, status: { _ in })
        XCTAssertEqual(plan.pipeline, .instructionEdit)
        XCTAssertEqual(plan.command, "mflux-generate-qwen-2.1-edit")
        XCTAssertEqual(plan.source(from: prompt), "/tmp/source.png")
        XCTAssertEqual(plan.strength, 1)
        let reusedStrength = await MLXStudioMedia.selectEditStrength(job: job, prompt: prompt, plan: plan, status: { _ in })
        XCTAssertEqual(reusedStrength, 0.9, "A remembered edit plan asks the agent for this request's strength")
        let repaired = try await MLXStudioMedia.selectImagePlan(job: job, prompt: prompt,
            previous: plan, failure: "test edit failure", status: { _ in })
        XCTAssertEqual(repaired.pipeline, .imageToImage)
        XCTAssertEqual(repaired.command, "mflux-generate-qwen-2.1")
        let fresh = MLXStudioMedia.ImagePlan(family: plan.family, pipeline: .textToImage)
        XCTAssertNil(fresh.source(from: prompt), "A new independent generation must not claim a refined source")
        let args = MLXStudioMedia.imageArguments(family: fresh.family, directory: root, prompt: "a new image",
            output: root.appending(path: "out.png"), settings: .init(), seed: 42,
            source: "/tmp/source.png", pipeline: .textToImage)
        XCTAssertFalse(args.contains("--image-path"))
        XCTAssertFalse(args.contains("--image-paths"))
    }
}
