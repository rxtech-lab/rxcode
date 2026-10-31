import Foundation

/// Shared by the video composer and local renderer. Stored separately from chat settings.
public struct VideoGenerationSettings: Codable, Equatable, Sendable {
    public static let storageKey = "localVideoGenerationSettings"

    public enum Quality: String, Codable, CaseIterable, Sendable {
        case low, medium, high, ultra, custom
        public var title: String { rawValue.capitalized }
    }

    public var quality: Quality = .low
    public var width = 640
    public var height = 384
    public var steps = 4
    public var frames = 25
    public var fps = 24
    public var seed = -1

    public init() {}

    public mutating func select(_ quality: Quality) {
        self.quality = quality
        switch quality {
        case .low: (width, height, steps) = (640, 384, 4)
        case .medium: (width, height, steps) = (896, 512, 12)
        case .high: (width, height, steps) = (1280, 768, 24)
        case .ultra: (width, height, steps) = (1536, 864, 40)
        case .custom: break
        }
    }

    /// Bound resource requests and align spatial/temporal dimensions for the video VAE.
    public var validated: Self {
        var value = self
        value.width = min(1920, max(256, width / 32 * 32))
        value.height = min(1920, max(256, height / 32 * 32))
        value.steps = min(100, max(1, steps))
        value.frames = (min(241, max(9, frames)) - 1) / 8 * 8 + 1
        value.fps = min(60, max(1, fps))
        value.seed = min(Int(Int32.max), max(-1, seed))
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
