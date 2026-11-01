import Foundation

/// What a local RxCode Agent model does, read from its saved Hugging Face
/// task (`pipeline_tag`). Everything but `.chat` gets a dedicated studio in
/// place of the message list, and answers each message with one tool call.
public enum LocalStudioKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case video
    case image
    case audio
    /// Fixed-choice classifiers such as the Jev-Style decision models.
    case decision

    public var id: String { rawValue }

    /// The studios — every kind but chat.
    public static let studios: [LocalStudioKind] = [.video, .image, .audio, .decision]

    public var isStudio: Bool { self != .chat }

    public static func kind(forPipelineTag tag: String?) -> LocalStudioKind {
        switch tag {
        case "text-to-video", "image-to-video", "video-to-video": .video
        case "text-to-image", "image-to-image": .image
        case "text-to-speech", "text-to-audio", "automatic-speech-recognition", "audio-text-to-text": .audio
        case "text-classification", "zero-shot-classification": .decision
        default: .chat
        }
    }

    public var title: String {
        switch self {
        case .chat: String(localized: "Chat", bundle: .module)
        case .video: String(localized: "Video", bundle: .module)
        case .image: String(localized: "Image", bundle: .module)
        case .audio: String(localized: "Audio", bundle: .module)
        case .decision: String(localized: "Decision", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .decision: "checklist"
        }
    }

    /// The tool a studio model calls for each message; its results are what
    /// the studio lists.
    public var toolName: String? {
        switch self {
        case .chat: nil
        case .video: VideoGenerationProgress.toolName
        case .image: "ImageGeneration"
        case .audio: "AudioGeneration"
        case .decision: "Decision"
        }
    }

    /// Every studio tool name; chat models never see these tools.
    public static var toolNames: Set<String> { Set(studios.compactMap(\.toolName)) }
}

/// Per-studio choices that apply to future generations: which engine runs
/// the model and which agent sets up missing components (companion files,
/// recipes). Each studio remembers its own, so video and audio can use
/// different agents.
public struct LocalStudioPreferences: Codable, Equatable, Sendable {
    /// A `LocalGenerationEngine` id; nil picks the model's default engine.
    public var engineID: String?
    /// The agent that looks up companion files; nil uses the default task
    /// agent from Settings → Tasks.
    public var setupAgent: TaskAgentConfig?

    public init(engineID: String? = nil, setupAgent: TaskAgentConfig? = nil) {
        self.engineID = engineID
        self.setupAgent = setupAgent
    }

    public static func storageKey(for kind: LocalStudioKind) -> String {
        "localStudioPreferences.\(kind.rawValue)"
    }

    public static func load(for kind: LocalStudioKind, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey(for: kind)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(for kind: LocalStudioKind, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey(for: kind))
    }
}
