import Foundation
import RxAgentCore
import RxAgentHarness
import enum RxCodeCore.LocalStudioKind

/// A studio message, split into what the user typed and what they attached.
/// Attachments reach the harness as prompt lines (`Attachment.promptContext`):
/// `[Attached image: /path]` for files and `[Pasted text:\n…\n]` for text.
nonisolated struct LocalStudioPrompt: Equatable, Sendable {
    var text: String
    /// Attached file paths, in order.
    var files: [String]
    var pastedTexts: [String]

    init(_ raw: String) {
        var files: [String] = []
        var pasted: [String] = []
        var kept: [String] = []
        var pasteBuffer: [String]?
        for line in raw.components(separatedBy: "\n") {
            if var buffer = pasteBuffer {
                if line == "]" {
                    pasted.append(buffer.joined(separator: "\n"))
                    pasteBuffer = nil
                } else {
                    buffer.append(line)
                    pasteBuffer = buffer
                }
                continue
            }
            if line == "[Pasted text:" {
                pasteBuffer = []
            } else if let match = line.wholeMatch(of: #/\[Attached [a-zA-Z]+: (.+)\]/#) {
                files.append(String(match.output.1))
            } else if line.wholeMatch(of: #/\[Link: .+\]/#) == nil {
                kept.append(line)
            }
        }
        // An unterminated paste is ordinary text.
        if let pasteBuffer { kept.append(contentsOf: ["[Pasted text:"] + pasteBuffer) }
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // `buildPromptWithAttachments` stands in for an empty message.
        if text == "See attached files", !(files.isEmpty && pasted.isEmpty) { text = "" }
        self.text = text
        self.files = files
        self.pastedTexts = pasted
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "bmp"]
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "aiff", "caf"]

    var images: [String] { files.filter { Self.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) } }
    var audio: [String] { files.filter { Self.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) } }
}

/// A "model" that answers each studio message by calling the studio's tool,
/// so the studio shows the result in its own view.
///
/// It has no language model of its own: a user message becomes one tool call
/// with that message as the prompt, and the tool's result ends the turn.
/// Image follow-ups also carry the latest successful image in this session.
nonisolated struct LocalStudioHarnessModel: HarnessModel {
    let modelID: String
    let kind: LocalStudioKind

    var contextWindow: Int? { nil }

    func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in Self.reply(to: request, modelID: modelID, kind: kind) { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    static func reply(to request: HarnessModelRequest, modelID: String, kind: LocalStudioKind) -> [HarnessModelChunk] {
        // Summaries and other one-off prompts are not studio requests, and a
        // returned tool result means this turn's output is done.
        guard request.mode == .streaming, let last = request.messages.last, last.role == .user,
              let toolName = kind.toolName else {
            return [.finished(reason: "stop")]
        }
        var prompt = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = LocalStudioPrompt(prompt)
        // Transcription runs on an attachment alone.
        guard !parsed.text.isEmpty || (kind == .audio && !parsed.audio.isEmpty) else {
            return [.textDelta(emptyPromptHint(for: kind)), .finished(reason: "stop")]
        }
        // Image conversations continue from the latest successful generation.
        // An explicit attachment overrides the thread's image. Keep missing
        // source paths so the tool reports an error instead of starting over.
        if kind == .image, parsed.images.isEmpty,
           let source = request.messages.dropLast().reversed().lazy.compactMap({ message -> String? in
               guard message.role == .tool, message.toolName == LocalStudioKind.image.toolName,
                     !message.isError,
                     let result = RxAgentCore.JSONValue(jsonString: message.text)?.objectValue,
                     let path = result["savedPath"]?.stringValue, !path.isEmpty else { return nil }
               return path
           }).first {
            prompt = "[Attached image: \(source)]\n\n" + prompt
        }
        let arguments: RxAgentCore.JSONValue = .object(["prompt": .string(prompt), "model": .string(modelID)])
        let json = (try? JSONEncoder().encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [.toolCall(HarnessToolCall(id: "\(kind.rawValue)-\(UUID().uuidString)", name: toolName, argumentsJSON: json)),
                .finished(reason: "tool_calls")]
    }

    static func emptyPromptHint(for kind: LocalStudioKind) -> String {
        switch kind {
        case .video: "Describe the video you want, for example: a red panda stepping along a mossy log in a misty forest, cinematic."
        case .image: "Describe the image you want, for example: a lighthouse on a cliff at dusk, oil painting."
        case .audio: "Type what to say, or attach an audio file to transcribe."
        case .decision: "Ask a question and add options, or state something to judge true or false."
        case .chat: ""
        }
    }
}

nonisolated enum LocalStudioTools {
    /// `2026-10-31-201502-red-panda-stepping.<ext>`
    static func fileName(for prompt: String, fallback: String, extension ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let words = prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        let slug = words.isEmpty ? fallback : words.joined(separator: "-")
        return "\(formatter.string(from: date))-\(slug).\(ext)"
    }

    static func failure(_ message: String, title: String) -> HarnessToolOutput {
        let json = (try? JSONEncoder().encode(["displayError": message])).map { String(decoding: $0, as: UTF8.self) } ?? message
        return HarnessToolOutput(text: json, isError: true, title: title)
    }

    /// A seed RxCode can record, so a take can be reproduced and refined.
    static func resolvedSeed(_ seed: Int) -> Int {
        seed >= 0 ? seed : Int.random(in: 0...Int(Int32.max))
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
