import Foundation

/// Shared by the audio composer and the local audio engines. Speech models
/// use the delivery and voice fields; transcription models use the language
/// and instruction.
public struct AudioGenerationSettings: Codable, Equatable, Sendable {
    public static let storageKey = "localAudioGenerationSettings"

    /// How much the speech sampler may vary: steadier reads repeat better,
    /// expressive reads vary pitch and pacing more.
    public enum Delivery: String, Codable, CaseIterable, Sendable {
        case steady, balanced, expressive, custom
        public var title: String { rawValue.capitalized }

        var temperature: Double? {
            switch self {
            case .steady: 0.3
            case .balanced: 0.6
            case .expressive: 0.9
            case .custom: nil
            }
        }
    }

    public var delivery: Delivery = .balanced
    public var temperature = 0.6
    /// Model-dependent voice name; empty uses the model's default.
    public var voice = ""
    /// ISO 639-1 code; empty lets the model decide.
    public var language = ""
    /// Upper bound on generated tokens, which caps the clip length.
    public var maxTokens = 4_096
    public var seed = -1
    /// What a transcription model is asked to do with the audio.
    public var transcriptionInstruction = "Transcribe this audio verbatim."

    public init() {}

    public mutating func select(_ delivery: Delivery) {
        self.delivery = delivery
        if let temperature = delivery.temperature { self.temperature = temperature }
    }

    public var validated: Self {
        var value = self
        value.temperature = min(2, max(0, temperature))
        value.voice = String(voice.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        value.language = String(language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(8))
        value.maxTokens = min(32_768, max(64, maxTokens))
        value.seed = min(Int(Int32.max), max(-1, seed))
        let instruction = transcriptionInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        value.transcriptionInstruction = instruction.isEmpty ? Self().transcriptionInstruction : String(instruction.prefix(1_000))
        return value
    }

    public var encoded: String {
        guard let data = try? JSONEncoder().encode(validated) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ string: String) -> Self {
        ((try? JSONDecoder().decode(Self.self, from: Data(string.utf8))) ?? Self()).validated
    }

    public static func load() -> Self {
        decode(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

extension AudioGenerationSettings {
    private enum CodingKeys: String, CodingKey {
        case delivery, temperature, voice, language, maxTokens, seed, transcriptionInstruction
    }

    /// Tolerant: settings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self()
        delivery = try container.decodeIfPresent(Delivery.self, forKey: .delivery) ?? fallback.delivery
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? fallback.temperature
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? fallback.maxTokens
        seed = try container.decodeIfPresent(Int.self, forKey: .seed) ?? fallback.seed
        transcriptionInstruction = try container.decodeIfPresent(String.self, forKey: .transcriptionInstruction)
            ?? fallback.transcriptionInstruction
    }
}
