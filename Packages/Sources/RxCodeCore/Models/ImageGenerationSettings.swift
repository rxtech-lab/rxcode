import Foundation

/// Shared by the image composer and the local image renderer. Stored
/// separately from chat and video settings.
///
/// Sampling steps and guidance depend on the model (a turbo model wants 4
/// steps and no guidance, SD 1.5 wants 25 and 7.0), so presets scale the
/// model's recommended values rather than fixing them. `custom` uses the
/// explicit values below.
public struct ImageGenerationSettings: Codable, Equatable, Sendable {
    public static let storageKey = "localImageGenerationSettings"

    public enum Quality: String, Codable, CaseIterable, Sendable {
        case low, medium, high, ultra, custom
        public var title: String { rawValue.capitalized }

        /// Long edge in pixels.
        var longEdge: Int {
            switch self {
            case .low: 512
            case .medium: 768
            case .high: 1024
            case .ultra, .custom: 1280
            }
        }

        /// Multiplier on the model's recommended steps.
        var stepScale: Double {
            switch self {
            case .low: 0.5
            case .medium: 1
            case .high: 1.5
            case .ultra, .custom: 2
            }
        }
    }

    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case square, landscape, portrait, wide
        public var title: String {
            switch self {
            case .square: "1:1"
            case .landscape: "4:3"
            case .portrait: "3:4"
            case .wide: "16:9"
            }
        }

        /// Width over height.
        var ratio: Double {
            switch self {
            case .square: 1
            case .landscape: 4.0 / 3
            case .portrait: 3.0 / 4
            case .wide: 16.0 / 9
            }
        }
    }

    public var quality: Quality = .medium
    public var aspect: Aspect = .square
    public var width = 768
    public var height = 768
    /// Custom only; 0 uses the model's recommendation.
    public var steps = 0
    /// Custom only; nil uses the model's recommendation.
    public var cfgScale: Double?
    public var seed = -1
    public var negativePrompt = ""
    /// How far a refine moves away from the source image: 0 keeps it, 1
    /// ignores it.
    public var refineStrength = 0.55

    public init() {}

    public mutating func select(_ quality: Quality) {
        self.quality = quality
        guard quality != .custom else { return }
        (width, height) = Self.size(longEdge: quality.longEdge, aspect: aspect)
    }

    public mutating func select(_ aspect: Aspect) {
        self.aspect = aspect
        (width, height) = Self.size(longEdge: max(width, height), aspect: aspect)
    }

    /// Dimensions rounded to the 64-pixel grid diffusion latents use.
    static func size(longEdge: Int, aspect: Aspect) -> (Int, Int) {
        let short = Int((Double(longEdge) / max(aspect.ratio, 1 / aspect.ratio)).rounded())
        let edge = longEdge / 64 * 64
        let other = max(256, (short + 32) / 64 * 64)
        return aspect.ratio >= 1 ? (edge, other) : (other, edge)
    }

    /// Steps for a model that recommends `recommended`.
    public func steps(recommended: Int) -> Int {
        if quality == .custom, steps > 0 { return steps }
        return min(150, max(1, Int((Double(recommended) * quality.stepScale).rounded())))
    }

    public func cfgScale(recommended: Double) -> Double {
        quality == .custom ? (cfgScale ?? recommended) : recommended
    }

    public var validated: Self {
        var value = self
        value.width = min(2048, max(256, width / 64 * 64))
        value.height = min(2048, max(256, height / 64 * 64))
        value.steps = min(150, max(0, steps))
        value.cfgScale = cfgScale.map { min(30, max(0, $0)) }
        value.seed = min(Int(Int32.max), max(-1, seed))
        value.refineStrength = min(1, max(0.05, refineStrength))
        value.negativePrompt = String(negativePrompt.prefix(2_000))
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

extension ImageGenerationSettings {
    private enum CodingKeys: String, CodingKey {
        case quality, aspect, width, height, steps, cfgScale, seed, negativePrompt, refineStrength
    }

    /// Tolerant: settings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self()
        quality = try container.decodeIfPresent(Quality.self, forKey: .quality) ?? fallback.quality
        aspect = try container.decodeIfPresent(Aspect.self, forKey: .aspect) ?? fallback.aspect
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? fallback.width
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? fallback.height
        steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? fallback.steps
        cfgScale = try container.decodeIfPresent(Double.self, forKey: .cfgScale)
        seed = try container.decodeIfPresent(Int.self, forKey: .seed) ?? fallback.seed
        negativePrompt = try container.decodeIfPresent(String.self, forKey: .negativePrompt) ?? ""
        refineStrength = try container.decodeIfPresent(Double.self, forKey: .refineStrength) ?? fallback.refineStrength
    }
}
