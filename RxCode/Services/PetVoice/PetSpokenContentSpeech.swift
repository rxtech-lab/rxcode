import Foundation
import RxAgentVoice

// MARK: - Spoken Content System Voice (Siri-capable) via `/usr/bin/say`

/// Renders speech with the voice chosen in System Settings → Accessibility →
/// Read & Speak (Spoken Content) → System Voice.
///
/// macOS does not expose Siri voices through `AVSpeechSynthesisVoice` or
/// `NSSpeechSynthesizer.availableVoices`, but `say` without `-v` speaks with the
/// Spoken Content system voice, which can be a Siri voice. Output is written to
/// a temporary 24 kHz mono WAV and decoded into playback frames.
nonisolated enum PetSpokenContentSpeech {
    /// `say` defaults to roughly 175–200 words per minute.
    private static let baseWordsPerMinute = 185.0

    static func stream(text: String, rateMultiplier: Double) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        let frames = try await render(text: text, rateMultiplier: rateMultiplier)
        return AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    static func render(text: String, rateMultiplier: Double) async throws -> [VoiceAudioFrame] {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "rxcode-spoken-content-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        let wordsPerMinute = Int((baseWordsPerMinute * max(0.5, min(2.0, rateMultiplier))).rounded())
        process.arguments = [
            "-o", outputURL.path,
            "--file-format=WAVE",
            "--data-format=LEI16@24000",
            "-r", String(wordsPerMinute),
            "--", text,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finished in
                    if finished.terminationReason == .exit, finished.terminationStatus == 0 {
                        continuation.resume()
                    } else if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let detail = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: VoiceError.unavailable(
                            detail.isEmpty
                                ? "The macOS system voice could not speak (exit \(finished.terminationStatus))."
                                : "The macOS system voice could not speak: \(detail)"
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()
        return try PetLocalSpeechSynthesizer.decodeAudioFileTo24kFrames(url: outputURL)
    }
}
