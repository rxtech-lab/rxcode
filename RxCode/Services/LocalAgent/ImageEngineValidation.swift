import Foundation
import ImageIO
import struct RxCodeCore.ImageGenerationSettings

/// A setup answer is a candidate until an actual engine run produces a decodable image.
/// Test artifacts never enter the user's generated-image history. Readiness is scoped
/// to this invocation, so replacing model/runtime files always triggers another test.
nonisolated enum ImageEngineValidation {
    static let prompt = "A red ceramic cup on a white table, studio photograph"

    static var settings: ImageGenerationSettings {
        var value = ImageGenerationSettings()
        value.select(.medium)
        value.width = 256
        value.height = 256
        value.seed = 42
        return value
    }

    static func checkImage(at output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 256, image.height == 256 else {
            throw MLXStudioMedia.Failure("Engine validation did not produce a decodable 256 × 256 image.")
        }
    }

    static func run<Candidate: Sendable>(
        initial: Candidate,
        test: (Candidate, URL) async throws -> Void,
        repair: (Candidate, String) async throws -> Candidate?,
        status: @Sendable (String) -> Void
    ) async throws -> Candidate {
        var candidate = initial
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appending(path: "rxcode-image-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appending(path: "check.png")
            do {
                status("Testing image engine (attempt \(attempt + 1) of 3)…")
                try await test(candidate, output)
                try Task.checkCancellation()
                try checkImage(at: output)
                status("Image engine ready — pipeline check passed")
                return candidate
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard attempt < 2 else {
                    throw MLXStudioMedia.Failure("Image engine validation failed after 3 attempts. \(error.localizedDescription)")
                }
                status("Image engine check failed. Asking the setup agent to repair it…")
                guard let revised = try await repair(candidate, error.localizedDescription) else { throw error }
                candidate = revised
            }
        }
        throw MLXStudioMedia.Failure("Image engine validation failed.")
    }

    /// Runs `generate` with the pipeline this chat session already settled on. The setup
    /// agent and the validation run only happen when the session has none yet, or when the
    /// remembered one fails; the failure is handed to `configure` so the agent can repair it.
    /// A nil `key` (no session) always configures.
    static func remembered<Config: Sendable, Output>(
        key: String?,
        configure: (_ failure: (config: Config, error: String)?) async throws -> Config,
        generate: (Config) async throws -> Output,
        status: @Sendable (String) -> Void
    ) async throws -> Output {
        var failure: (config: Config, error: String)?
        if let key, let saved = await ImagePipelineMemory.shared.value(for: key, as: Config.self) {
            status("Using this session's image pipeline")
            do {
                return try await generate(saved)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                await ImagePipelineMemory.shared.forget(key)
                status("This session's image pipeline failed. Asking the setup agent to reconfigure it…")
                failure = (saved, error.localizedDescription)
            }
        }
        let config = try await configure(failure)
        if let key { await ImagePipelineMemory.shared.remember(config, for: key) }
        do {
            return try await generate(config)
        } catch {
            if let key, !(error is CancellationError) { await ImagePipelineMemory.shared.forget(key) }
            throw error
        }
    }
}

/// The image pipeline and configuration each chat session's setup agent decided on,
/// keyed by session, model and request shape (e.g. whether a source image is attached).
actor ImagePipelineMemory {
    static let shared = ImagePipelineMemory()
    private var entries: [String: any Sendable] = [:]

    static func key(session: String, model: String, variant: String = "") -> String {
        "\(session)|\(model)|\(variant)"
    }

    func value<Config: Sendable>(for key: String, as _: Config.Type) -> Config? { entries[key] as? Config }
    func remember(_ config: any Sendable, for key: String) { entries[key] = config }
    func forget(_ key: String) { entries[key] = nil }
}
