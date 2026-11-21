import Foundation
import RxAgentVoice
import RxCodeCore

nonisolated struct FlowcySpeechVoice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    var locale: String? = nil

    var languageName: String? {
        locale.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
    }
}

nonisolated struct FlowcySpeechSelection: Codable, Equatable, Sendable {
    let model: FlowcyMediaModel
    let voice: FlowcySpeechVoice
}

extension FlowcyMediaModel {
    nonisolated enum SpeechProvider { case azure, gemini, gateway }

    nonisolated var speechProvider: SpeechProvider {
        switch provider {
        case "azure": .azure
        case "google", "gemini": .gemini
        default: .gateway
        }
    }

    /// The pet and the media tool use the same Flowcy speech request contract.
    nonisolated func speechBody(text: String, options: [String: JSONValue], locale: String = "en-US") throws -> [String: JSONValue] {
        var body = options
        body["model"] = .string(id)
        switch speechProvider {
        case .gemini:
            body["provider"] = .string("gemini")
            body["transcript"] = .string(text)
            body["speakers"] = options["speakers"] ?? .array([.object([
                "name": .string("Speaker"), "voice": options["voice"] ?? .string("Kore")
            ])])
        case .azure:
            guard let voice = options["voice"]?.stringValue, !voice.isEmpty else {
                throw IDEToolError.invalidArguments("Azure speech requires options.voice.")
            }
            func escaped(_ value: String) -> String {
                value.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "'", with: "&apos;")
            }
            body["provider"] = .string("azure")
            body["ssml"] = .string("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(escaped(locale))'><voice name='\(escaped(voice))'>\(escaped(text))</voice></speak>")
        case .gateway:
            guard let voice = options["voice"]?.stringValue, !voice.isEmpty else {
                throw IDEToolError.invalidArguments("Speech generation requires options.voice.")
            }
            body["provider"] = .string("gateway")
            body["text"] = .string(text)
        }
        return body
    }
}

extension FlowcyMediaClient {
    func speechVoices(for model: FlowcyMediaModel) async throws -> [FlowcySpeechVoice] {
        switch model.speechProvider {
        case .azure:
            let response = try await request("ai/voices", queryItems: [.init(name: "provider", value: "azure")])
            guard let voices = response.arrayValue else {
                throw IDEToolError.handlerFailed("Flowcy returned an invalid Azure voice catalog.")
            }
            let wantsHD = model.id == "azure-hd-tts"
            return voices.compactMap { item -> FlowcySpeechVoice? in
                guard let id = item["ShortName"]?.stringValue, !id.isEmpty,
                      let locale = item["Locale"]?.stringValue,
                      id.localizedCaseInsensitiveContains("DragonHD") == wantsHD else { return nil }
                return FlowcySpeechVoice(id: id, name: item["DisplayName"]?.stringValue ?? id, locale: locale)
            }.sorted { $0.id < $1.id }
        case .gemini:
            let names = ["Achernar", "Achird", "Algenib", "Algieba", "Alnilam", "Aoede", "Autonoe", "Callirrhoe",
                         "Charon", "Despina", "Enceladus", "Erinome", "Fenrir", "Gacrux", "Iapetus", "Kore",
                         "Laomedeia", "Leda", "Orus", "Puck", "Pulcherrima", "Rasalgethi", "Sadachbia",
                         "Sadaltager", "Schedar", "Sulafat", "Umbriel", "Vindemiatrix", "Zephyr", "Zubenelgenubi"]
            return names.map { FlowcySpeechVoice(id: $0, name: $0) }
        case .gateway:
            if model.id.hasPrefix("elevenlabs/") {
                // The same named ElevenLabs voices offered by Flowcy's model playground.
                return [
                    .init(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah"), .init(id: "nPczCjzI2devNBz1zQrb", name: "Brian"),
                    .init(id: "cgSgspJ2msm6clMCkdW9", name: "Jessica"), .init(id: "bIHbv24MWmeRgasZH58o", name: "Will"),
                    .init(id: "hpp4J3VqNfWAUOO0d1Us", name: "Bella"), .init(id: "CwhRBWXzGAHq8TQ4Fs17", name: "Roger"),
                    .init(id: "FGY2WhTYpPnrIDTdsKH5", name: "Laura"), .init(id: "IKne3meq5aSn9XLyUdCD", name: "Charlie")
                ]
            }
            if model.id.hasPrefix("openai/tts-1") || model.id.hasPrefix("openai/gpt-4o-mini-tts") {
                // https://developers.openai.com/api/docs/guides/text-to-speech#voice-options
                var names = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]
                if model.id.hasPrefix("openai/gpt-4o-mini-tts") { names += ["ballad", "cedar", "marin", "verse"] }
                return names.sorted().map { FlowcySpeechVoice(id: $0, name: $0.capitalized) }
            }
            return [] // Other Gateway models accept a provider-specific voice ID.
        }
    }

    func speechFrames(text: String, selection: FlowcySpeechSelection) async throws -> [VoiceAudioFrame] {
        let body = try selection.model.speechBody(
            text: text, options: ["voice": .string(selection.voice.id)], locale: selection.voice.locale ?? "en-US"
        )
        let result = try await request("ai/speech", body: .object(body))
        return try await Self.decodeSpeech(result)
    }

    @concurrent nonisolated private static func decodeSpeech(_ response: JSONValue) async throws -> [VoiceAudioFrame] {
        try Task.checkCancellation()
        guard let encoded = response["audio_base64"]?.stringValue,
              let audio = Data(base64Encoded: encoded), !audio.isEmpty else {
            throw VoiceError.unavailable("Flowcy returned no speech audio.")
        }
        let mime = response["mime_type"]?.stringValue ?? "audio/wav"
        let ext = mime.contains("mpeg") || mime.contains("mp3") ? "mp3" : mime.contains("ogg") ? "ogg" : "wav"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rxcode-pet-\(UUID()).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try audio.write(to: url)
        let frames = try PetLocalSpeechSynthesizer.decodeAudioFileTo24kFrames(url: url)
        guard !frames.isEmpty else { throw VoiceError.unavailable("The selected Flowcy voice produced no audio.") }
        try Task.checkCancellation()
        return frames
    }
}
