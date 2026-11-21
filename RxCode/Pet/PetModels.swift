import Foundation
import RxCodeCore

// MARK: - Pet Mood, Status & Motion

nonisolated enum PetMood: String, Codable, CaseIterable, Identifiable, Sendable {
    case neutral
    case happy
    case focused
    case curious
    case sleepy
    case concerned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: "Calm"
        case .happy: "Happy"
        case .focused: "Focused"
        case .curious: "Curious"
        case .sleepy: "Sleepy"
        case .concerned: "Concerned"
        }
    }

    var expressionColumn: Int {
        switch self {
        case .neutral: 0
        case .happy: 1
        case .focused: 2
        case .curious: 3
        case .sleepy: 4
        case .concerned: 5
        }
    }
}

nonisolated enum PetStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case idle
    case listening
    case userSpeaking
    case thinking
    case working
    case speaking
    case sleeping
    case celebrating
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .userSpeaking: "Hearing you…"
        case .thinking: "Thinking…"
        case .working: "Running tools…"
        case .speaking: "Speaking"
        case .sleeping: "Resting"
        case .celebrating: "Work complete!"
        case .failed: "Needs attention"
        }
    }
}

nonisolated enum PetMotion: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case idle
    case working
    case waiting
    case resting
    case waving
    case walking
    case celebration
    case failure

    var id: String { rawValue }

    var rowIndex: Int {
        switch self {
        case .automatic, .idle: 0
        case .working: 1
        case .waiting: 2
        case .resting: 3
        case .waving: 4
        case .walking: 5
        case .celebration: 6
        case .failure: 7
        }
    }

    var defaultFrameDuration: TimeInterval {
        switch self {
        case .automatic, .idle: 0.24
        case .working: 0.10
        case .waiting: 0.16
        case .resting: 0.28
        case .waving: 0.12
        case .walking: 0.09
        case .celebration: 0.11
        case .failure: 0.13
        }
    }
}

// Finite gestures reuse the pixel frames with distinct body choreography.
nonisolated enum PetGesture: CaseIterable, Sendable {
    case inspect, nod, stretch, hop, shuffle, greet, scan, tap, balance

    static func choices(for status: PetStatus, excluding previous: Self?) -> [Self] {
        let actions: [Self]
        switch status {
        case .thinking, .working: actions = [.inspect, .nod, .stretch, .shuffle, .scan, .tap]
        case .idle: actions = [.inspect, .stretch, .hop, .shuffle, .greet, .scan, .balance]
        case .speaking: actions = [.nod, .inspect, .greet, .balance]
        default: actions = []
        }
        return actions.filter { $0 != previous }
    }

    static func restRange(for status: PetStatus) -> ClosedRange<Double> {
        switch status {
        case .idle: 3...6
        case .speaking: 1.2...2.8
        default: 2.5...6
        }
    }

    var motion: PetMotion {
        switch self {
        case .inspect, .scan: .waiting
        case .nod, .tap: .working
        case .stretch, .balance: .resting
        case .hop: .celebration
        case .shuffle: .walking
        case .greet: .waving
        }
    }

    var duration: Double {
        switch self {
        case .shuffle, .scan: 1.8
        case .balance: 2.1
        case .tap: 1.6
        default: 1.4
        }
    }

    struct Pose {
        var x: Double = 0
        var y: Double = 0
        var rotation: Double = 0
        var scaleX: Double = 1
        var scaleY: Double = 1
    }

    func pose(at elapsed: Double) -> Pose {
        let progress = min(1, max(0, elapsed / duration))
        // All gestures start and end at the neutral transform.
        let arc = sin(.pi * progress)
        let sway = sin(2 * .pi * progress) * arc
        switch self {
        case .inspect: return Pose(x: sway * 0.025, rotation: arc * -9)
        case .nod: return Pose(y: sin(4 * .pi * progress) * arc * 0.025,
                               scaleY: 1 - abs(sway) * 0.035)
        case .stretch: return Pose(y: -arc * 0.025, scaleX: 1 - arc * 0.06, scaleY: 1 + arc * 0.08)
        case .hop: return Pose(y: -arc * 0.11, rotation: sway * 7)
        case .shuffle: return Pose(x: sway * 0.09, y: -abs(sin(4 * .pi * progress)) * arc * 0.02,
                                   rotation: sway * 4)
        case .greet: return Pose(rotation: sway * 6)
        case .scan:
            // Look left, pause near center, then look right before settling.
            return Pose(x: sway * 0.035, rotation: sway * 12, scaleX: 1 - arc * 0.025)
        case .tap:
            // Three small, damped tool-working beats rather than a repeating loop.
            let beat = sin(6 * .pi * progress) * arc
            return Pose(y: -abs(beat) * 0.018, rotation: beat * 3,
                        scaleX: 1 + abs(beat) * 0.025, scaleY: 1 - abs(beat) * 0.04)
        case .balance:
            return Pose(x: arc * 0.04, y: -arc * 0.035,
                        rotation: arc * 11 + sway * 3, scaleY: 1 + arc * 0.025)
        }
    }
}

// MARK: - Speech Bubble & Quick Actions

nonisolated enum PetQuickAction: Equatable, Sendable {
    case openCompanion
    case openVoiceSettings
    case openDailyReport
    case openThread(projectId: UUID, sessionId: String)
    case openPendingPrompt
    case openURL(URL)

    var title: String {
        switch self {
        case .openCompanion: "Open Companion"
        case .openVoiceSettings: "Voice Settings…"
        case .openDailyReport: "View Report"
        case .openThread: "Open Thread"
        case .openPendingPrompt: "Review Prompt"
        case .openURL: "View CI Run"
        }
    }

    var systemImage: String {
        switch self {
        case .openCompanion: "waveform.and.mic"
        case .openVoiceSettings: "gearshape"
        case .openDailyReport: "doc.text.magnifyingglass"
        case .openThread: "bubble.left.and.text.bubble.right"
        case .openPendingPrompt: "checkmark.shield"
        case .openURL: "arrow.up.right.square"
        }
    }
}

nonisolated struct PetBubbleMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String?
    var text: String
    var createdAt: Date
    var isProactive: Bool
    var action: PetQuickAction?

    init(
        id: UUID = UUID(),
        title: String? = nil,
        text: String,
        createdAt: Date = Date(),
        isProactive: Bool = false,
        action: PetQuickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.isProactive = isProactive
        self.action = action
    }
}

nonisolated struct PetState: Equatable, Sendable {
    var mood: PetMood = .neutral
    var status: PetStatus = .idle
    var motion: PetMotion = .automatic
    var isWalking: Bool = false
    var activeToolName: String?
    var bubble: PetBubbleMessage?
    var patReactionCount: Int = 0

    var resolvedMotion: PetMotion {
        if isWalking { return .walking }
        if motion != .automatic { return motion }
        switch status {
        case .idle:
            return mood == .sleepy ? .resting : .idle
        case .listening, .userSpeaking:
            return .waiting
        case .thinking, .working:
            return .working
        case .speaking:
            return .waving
        case .sleeping:
            return .resting
        case .celebrating:
            return .celebration
        case .failed:
            return .failure
        }
    }

    var resolvedMood: PetMood {
        if mood != .neutral { return mood }
        switch status {
        case .idle: return .neutral
        case .listening, .userSpeaking: return .curious
        case .thinking, .working: return .focused
        case .speaking: return .happy
        case .sleeping: return .sleepy
        case .celebrating: return .happy
        case .failed: return .concerned
        }
    }
}

// MARK: - Sprite Character & Animation Manifest

nonisolated struct PetAnimationManifest: Codable, Equatable, Sendable {
    struct Mouth: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct FrameSpec: Codable, Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let faceX: Double?
        let faceY: Double?
        let faceSize: Double?
        let duration: Double?
        var mouth: Mouth? = nil
    }

    let version: Int
    let frameWidth: Int
    let frameHeight: Int
    let frames: [FrameSpec]
}

nonisolated struct PetCharacter: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    let spriteSheetURL: URL?
    let expressionsURL: URL?
    let animationManifestURL: URL?
    let frameColumns: Int
    let frameRows: Int
    let overlaysExpressions: Bool

    var additionalSpriteSheetURLs: [URL] = []
    var spriteFrameDuration: TimeInterval? = nil

    /// Normalized mouth rectangle for legacy and portable sprite packs.
    var speechMouth: PetAnimationManifest.Mouth? = nil
    var closedMouthSheetURLs: [URL] = []
    var openMouthSheetURLs: [URL] = []

    var lookHue: Double = 0
    var lookSaturation: Double = 1
    var lookAccessory: String = "none"

    static let rxcodeBuddy: PetCharacter = {
        var character = PetCharacter(id: "rxcode-buddy", displayName: "RxBuddy",
            spriteSheetURL: resolveResource(name: "pet-robot-1", ext: "png"), expressionsURL: nil,
            animationManifestURL: resolveResource(name: "pet-robot-1", ext: "json"),
            frameColumns: 6, frameRows: 8, overlaysExpressions: false)
        character.additionalSpriteSheetURLs = (2...4).compactMap { resolveResource(name: "pet-robot-\($0)", ext: "png") }
        character.closedMouthSheetURLs = (1...4).compactMap { resolveResource(name: "pet-robot-\($0)-closed", ext: "png") }
        character.openMouthSheetURLs = (1...4).compactMap { resolveResource(name: "pet-robot-\($0)-open", ext: "png") }
        character.spriteFrameDuration = 0.08
        return character
    }()

    static func preset(_ kind: String) -> PetCharacter {
        if kind == "robot" { return .rxcodeBuddy }
        let urls = (1...4).compactMap { resolveResource(name: "pet-\(kind)-\($0)", ext: "png") }
        guard urls.count == 4 else { return .rxcodeBuddy }
        var character = PetCharacter(id: "preset-\(kind)", displayName: kind.capitalized,
            spriteSheetURL: urls[0], expressionsURL: nil, animationManifestURL: resolveResource(name: "pet-\(kind)-1", ext: "json"),
            frameColumns: 6, frameRows: 8, overlaysExpressions: false)
        character.additionalSpriteSheetURLs = Array(urls.dropFirst())
        character.closedMouthSheetURLs = (1...4).compactMap { resolveResource(name: "pet-\(kind)-\($0)-closed", ext: "png") }
        character.openMouthSheetURLs = (1...4).compactMap { resolveResource(name: "pet-\(kind)-\($0)-open", ext: "png") }
        character.spriteFrameDuration = 0.08
        return character
    }

    private static func resolveResource(name: String, ext: String) -> URL? {
        if let flat = Bundle.main.url(forResource: name, withExtension: ext) {
            return flat
        }
        if let nested = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Pet") {
            return nested
        }
        // Fallback for unit test targets where source tree resources may sit next to the project root.
        let sourceCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Pet/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: sourceCandidate.path) {
            return sourceCandidate
        }
        return nil
    }
}

// MARK: - Voice & Companion Configuration

nonisolated enum PetVoiceModeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codexRealtime
    case localPipeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexRealtime:
            "Codex Realtime"
        case .localPipeline:
            "Local Speech + Custom Agent"
        }
    }

    var shortTitle: String {
        switch self {
        case .codexRealtime: "Codex Realtime"
        case .localPipeline: "Local + Custom Agent"
        }
    }

    var summary: String {
        switch self {
        case .codexRealtime:
            "Low-latency bidirectional voice powered by Codex Realtime (WebRTC or WebSocket) with RxCode IDE tools."
        case .localPipeline:
            "Speech recognition runs on this Mac. Your general agent answers using the selected speech voice."
        }
    }
}

nonisolated enum CodexRealtimeTransportPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case webRTC
    case websocket

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webRTC: "WebRTC (Recommended — works with ChatGPT sign-in & API key)"
        case .websocket: "WebSocket (Requires OpenAI API key auth)"
        }
    }
}

nonisolated enum CodexRealtimeVoicePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case juniper
    case maple
    case spruce
    case ember
    case vale
    case breeze
    case arbor
    case sol
    case cove
    case aube
    case bubbie
    case haetsal
    case hanul
    case himari
    case leher
    case miko
    case neer
    case porto
    case rindo
    case rio
    case rivage
    case selva
    case sonna
    case tinta
    case viola

    static let defaultVoice: Self = .juniper

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

nonisolated enum PetLocalSpeechSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech
    case localWhisperModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: "macOS On-Device Speech Recognition"
        case .localWhisperModel: "Installed Local Transcription Model (MLX / GGUF)"
        }
    }
}

nonisolated enum PetProactiveMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case voiceAndBubble
    case bubbleOnly
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voiceAndBubble: "Speak Aloud & Show Bubble"
        case .bubbleOnly: "Show Bubble Only (Silent)"
        case .off: "Off"
        }
    }
}

nonisolated struct PetConfiguration: Codable, Equatable, Sendable {
    static let defaultsKey = "rxcode.pet.configuration.v1"
    static let systemTTSModelID = "system"
    /// `systemVoiceIdentifier` sentinel that renders through `/usr/bin/say` with no
    /// `-v`, so speech uses the Spoken Content "System Voice". That is the only
    /// supported path for apps to reach Siri voices, which macOS does not list in
    /// `AVSpeechSynthesisVoice.speechVoices()`.
    static let spokenContentSystemVoiceID = "rxcode.spoken-content-system-voice"

    var isEnabled: Bool = false
    var petSize: Double = 112
    var normalizedScreenX: Double? = nil
    var normalizedScreenY: Double? = nil

    // Voice mode selection
    var voiceMode: PetVoiceModeKind = .codexRealtime

    // Mode 1: Codex Realtime
    var codexTransport: CodexRealtimeTransportPreference = .webRTC
    var codexVoice: String = CodexRealtimeVoicePreset.defaultVoice.rawValue

    var resolvedCodexVoice: CodexRealtimeVoicePreset {
        CodexRealtimeVoicePreset(rawValue: codexVoice) ?? .defaultVoice
    }
    var codexRealtimeModel: String = ""

    /// Nil keeps the existing automatic conversation language for older preferences.
    var conversationLanguageIdentifier: String? = nil

    static let supportedConversationLocales: [(id: String, label: String)] = [
        ("en-US", "English (United States)"), ("en-GB", "English (United Kingdom)"),
        ("ja-JP", "Japanese (Japan)"), ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"), ("es-ES", "Spanish (Spain)"),
        ("fr-FR", "French (France)"), ("de-DE", "German (Germany)"),
        ("ko-KR", "Korean (South Korea)")
    ]

    var conversationLanguageInstruction: String {
        guard let identifier = conversationLanguageIdentifier,
              let language = Self.supportedConversationLocales.first(where: { $0.id == identifier }) else { return "" }
        return "Conversation language: \(language.label) (\(language.id)). Respond and speak in this language, including notification announcements and background updates, unless the user explicitly requests another language. Translate event summaries into this language; keep names and code identifiers intact."
    }

    // Local Speech + Custom Agent, and speech outside a call
    var localSpeechSource: PetLocalSpeechSource = .appleSpeech
    var speechLocaleIdentifier: String = Locale.current.identifier
    var localSTTModelID: String? = nil
    /// General agent for typed chat, daily reports, and local speech. Nil follows the workspace task agent.
    var customAgent: TaskAgentConfig? = nil
    /// Nil selects Apple Intelligence, including preferences saved before this setting existed.
    var notificationAgent: TaskAgentConfig? = nil
    /// `"system"` for macOS `AVSpeechSynthesizer` fallback, or an installed `LocalModelInfo.id`.
    var localTTSModelID: String = PetConfiguration.systemTTSModelID
    var localTTSVoicePreset: String = "af_heart"
    /// Nil uses the saved Apple or installed model voice, including for older preferences.
    var flowcyVoice: FlowcySpeechSelection?

    func usesLocalVoice(modelID: String) -> Bool {
        flowcyVoice == nil && localTTSModelID == modelID
    }

    mutating func selectLocalVoice(modelID: String) {
        localTTSModelID = modelID
        flowcyVoice = nil
    }
    /// Optional for compatibility with saved preferences predating seed support.
    /// Legacy negative seeds resolve to the stable default instead of changing each utterance.
    var localTTSSeed: Int? = nil

    var resolvedLocalTTSSeed: Int {
        let seed = localTTSSeed ?? 42
        return seed < 0 ? 42 : min(seed, Int(Int32.max))
    }

    var systemVoiceIdentifier: String? = nil
    var speechRate: Double = 1.0

    /// Optional so preferences saved before activity cues were configurable still decode.
    var toolSoundsEnabled: Bool? = nil
    var playsToolSounds: Bool { toolSoundsEnabled ?? true }

    /// Mutes pet microphone input and voice output. Older preferences omit this field.
    var isMuted: Bool? = nil

    // Audio routing. `nil` follows the macOS system default device.
    var microphoneDeviceUID: String? = nil
    var speakerDeviceUID: String? = nil

    var usesCustomAudioDevices: Bool {
        !(microphoneDeviceUID ?? "").isEmpty || !(speakerDeviceUID ?? "").isEmpty
    }

    // Target project scope for IDE tools / thread creation
    var pinnedProjectId: UUID? = nil

    // Proactive talk & daily report
    var proactiveMode: PetProactiveMode = .voiceAndBubble
    var dailyReportAutoEnabled: Bool = false
    var dailyReportHour: Int = 9
    var dailyReportMinute: Int = 30
    var lastAutoDailyReportDayKey: String? = nil

    static func load(from defaults: UserDefaults = .standard) -> PetConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode(PetConfiguration.self, from: data) else {
            return PetConfiguration()
        }
        decoded.codexVoice = decoded.resolvedCodexVoice.rawValue
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
