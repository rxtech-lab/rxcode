import Foundation

/// A generation setting a studio engine can apply. The setup agent reads a
/// model's README and picks which of these the model honors, with the
/// model's own ranges, defaults and choices; it cannot invent new ones,
/// because every key maps to a flag the engine already passes.
public enum StudioParameterKey: String, Codable, CaseIterable, Sendable {
    case width, height, steps, frames, fps, guidance, seed
    case negativePrompt = "negative_prompt"
    case refineStrength = "refine_strength"
    case temperature, voice, language
    case maxTokens = "max_tokens"
    case transcriptionInstruction = "transcription_instruction"

    public enum ValueType: Sendable { case integer, number, text }

    public var valueType: ValueType {
        switch self {
        case .width, .height, .steps, .frames, .fps, .seed, .maxTokens: .integer
        case .guidance, .refineStrength, .temperature: .number
        case .negativePrompt, .voice, .language, .transcriptionInstruction: .text
        }
    }

    /// The engine's hard limits; a generated range is clamped inside them.
    public var bounds: ClosedRange<Double>? {
        switch self {
        case .width, .height: 256...2048
        case .steps: 1...150
        case .frames: 9...241
        case .fps: 1...60
        case .guidance: 0...30
        case .seed: -1...Double(Int32.max)
        case .refineStrength: 0.05...1
        case .temperature: 0...2
        case .maxTokens: 64...32_768
        case .negativePrompt, .voice, .language, .transcriptionInstruction: nil
        }
    }

    /// What each studio's engines can apply.
    public static func supported(for kind: LocalStudioKind) -> [Self] {
        switch kind {
        case .video: [.width, .height, .steps, .frames, .fps, .seed]
        case .image: [.width, .height, .steps, .guidance, .seed, .negativePrompt, .refineStrength]
        case .audio: [.temperature, .voice, .language, .maxTokens, .seed, .transcriptionInstruction]
        case .decision, .chat: []
        }
    }
}

/// A setting's value: numbers for numeric keys, text otherwise.
public enum StudioValue: Codable, Equatable, Hashable, Sendable {
    case number(Double)
    case text(String)

    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var text: String? { if case .text(let value) = self { value } else { nil } }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    /// A display string: integers without a fraction.
    public var display: String {
        switch self {
        case .number(let value):
            value == value.rounded() ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(0...2)))
        case .text(let value): value
        }
    }
}

/// One control in a model's generated settings form.
public struct StudioParameter: Codable, Equatable, Identifiable, Sendable {
    public enum Control: String, Codable, Sendable {
        case slider, stepper, choice, text
    }

    public var key: StudioParameterKey
    public var label: String
    public var help: String?
    public var control: Control
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    /// `choice` only: the values the README lists, e.g. voices or resolutions.
    public var options: [StudioValue]?
    public var defaultValue: StudioValue

    public var id: String { key.rawValue }

    public init(key: StudioParameterKey, label: String, help: String? = nil, control: Control,
                minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil,
                options: [StudioValue]? = nil, defaultValue: StudioValue) {
        self.key = key
        self.label = label
        self.help = help
        self.control = control
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.options = options
        self.defaultValue = defaultValue
    }

    /// `value` fitted to this control: numbers clamped and stepped, choices
    /// kept only when listed. Nil when it can't be used.
    public func sanitize(_ value: StudioValue) -> StudioValue? {
        if let options, !options.isEmpty {
            if options.contains(value) { return value }
            // A number given as text, or the reverse, still matches.
            return options.first { $0.display == value.display }
        }
        switch key.valueType {
        case .integer, .number:
            guard var number = value.number ?? value.text.flatMap(Double.init), number.isFinite else { return nil }
            if let minimum { number = max(minimum, number) }
            if let maximum { number = min(maximum, number) }
            if key.valueType == .integer { number = number.rounded() }
            return .number(number)
        case .text:
            guard let text = value.text ?? value.number.map({ StudioValue.number($0).display }) else { return nil }
            return .text(String(text.prefix(2_000)))
        }
    }
}

/// Generation settings the setup agent derived from one model's README, and
/// the values the user (or the agent, in auto mode) chose for them.
public struct StudioModelConfig: Codable, Equatable, Sendable {
    public static let storageKey = "localStudioModelConfigs"

    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// The values below apply to every generation.
        case manual
        /// The setup agent picks values for each prompt, starting from these.
        case auto

        public var title: String {
            switch self {
            case .manual: String(localized: "Manual", bundle: .module)
            case .auto: String(localized: "Auto", bundle: .module)
            }
        }
    }

    public var modelID: String
    public var kind: LocalStudioKind
    public var parameters: [StudioParameter]
    public var values: [StudioParameterKey: StudioValue]
    public var mode: Mode
    /// The agent's one-paragraph reading of the model card.
    public var summary: String?
    /// "Claude · Haiku" — the agent that generated the form.
    public var generatedBy: String?
    public var generatedAt: Date

    public init(modelID: String, kind: LocalStudioKind, parameters: [StudioParameter],
                values: [StudioParameterKey: StudioValue] = [:], mode: Mode = .manual,
                summary: String? = nil, generatedBy: String? = nil, generatedAt: Date = Date()) {
        self.modelID = modelID
        self.kind = kind
        self.parameters = parameters
        self.values = values
        self.mode = mode
        self.summary = summary
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
    }

    /// The chosen value for each parameter, falling back to its default.
    public var resolvedValues: [StudioParameterKey: StudioValue] {
        var resolved: [StudioParameterKey: StudioValue] = [:]
        for parameter in parameters {
            resolved[parameter.key] = values[parameter.key].flatMap(parameter.sanitize) ?? parameter.defaultValue
        }
        return resolved
    }

    /// `overrides` fitted to this form; unknown keys and unusable values are dropped.
    public func sanitized(_ overrides: [StudioParameterKey: StudioValue]) -> [StudioParameterKey: StudioValue] {
        var result: [StudioParameterKey: StudioValue] = [:]
        for parameter in parameters {
            if let value = overrides[parameter.key], let clean = parameter.sanitize(value) { result[parameter.key] = clean }
        }
        return result
    }

    // MARK: - Storage

    public static func decodeAll(_ string: String) -> [String: StudioModelConfig] {
        (try? JSONDecoder().decode([String: StudioModelConfig].self, from: Data(string.utf8))) ?? [:]
    }

    public static func encodeAll(_ configs: [String: StudioModelConfig]) -> String {
        guard let data = try? JSONEncoder().encode(configs) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func load(modelID: String) -> StudioModelConfig? {
        decodeAll(UserDefaults.standard.string(forKey: storageKey) ?? "")[modelID]
    }

    public static func save(_ config: StudioModelConfig) {
        var all = decodeAll(UserDefaults.standard.string(forKey: storageKey) ?? "")
        all[config.modelID] = config
        UserDefaults.standard.set(encodeAll(all), forKey: storageKey)
    }

    /// Models whose form the setup agent is building right now, so every
    /// window's composer can show it. Cleared at launch.
    public static let pendingStorageKey = "localStudioModelConfigsPending"

    public static func decodePending(_ string: String) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(string.utf8))) ?? [])
    }

    public static func isPending(modelID: String) -> Bool {
        decodePending(UserDefaults.standard.string(forKey: pendingStorageKey) ?? "").contains(modelID)
    }

    public static func setPending(_ pending: Bool, modelID: String) {
        var all = decodePending(UserDefaults.standard.string(forKey: pendingStorageKey) ?? "")
        if pending { all.insert(modelID) } else { all.remove(modelID) }
        let data = (try? JSONEncoder().encode(all.sorted())) ?? Data()
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: pendingStorageKey)
    }

    public static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingStorageKey)
    }

    public static func remove(modelID: String) {
        var all = decodeAll(UserDefaults.standard.string(forKey: storageKey) ?? "")
        all[modelID] = nil
        UserDefaults.standard.set(encodeAll(all), forKey: storageKey)
    }

    // MARK: - Agent replies

    /// The form from the setup agent's reply:
    /// `{"summary": "...", "parameters": [{"key", "label", "help", "control",
    /// "min", "max", "step", "options", "default"}]}`. Parameters with keys the
    /// studio's engines can't apply are dropped, ranges are clamped to the
    /// engine's limits and defaults fitted to the range. Nil when nothing usable remains.
    public static func parse(reply: String, modelID: String, kind: LocalStudioKind, generatedBy: String? = nil) -> StudioModelConfig? {
        guard let object = jsonObject(in: reply), let rawParameters = object["parameters"] as? [[String: Any]] else { return nil }
        let supported = StudioParameterKey.supported(for: kind)
        var seen = Set<StudioParameterKey>()
        var parameters: [StudioParameter] = []
        for raw in rawParameters {
            guard let rawKey = raw["key"] as? String, let key = StudioParameterKey(rawValue: rawKey),
                  supported.contains(key), !seen.contains(key) else { continue }
            if let parameter = parameter(raw, key: key) {
                parameters.append(parameter)
                seen.insert(key)
            }
        }
        guard !parameters.isEmpty else { return nil }
        let summary = (object["summary"] as? String).map { String($0.prefix(1_200)) }
        return StudioModelConfig(modelID: modelID, kind: kind, parameters: parameters, summary: summary, generatedBy: generatedBy)
    }

    /// Values from an auto-mode reply, `{"values": {"steps": 20, ...}}` or a
    /// bare object, fitted to this form.
    public func parseValues(reply: String) -> [StudioParameterKey: StudioValue]? {
        guard let object = Self.jsonObject(in: reply) else { return nil }
        let raw = (object["values"] as? [String: Any]) ?? object
        var overrides: [StudioParameterKey: StudioValue] = [:]
        for (rawKey, rawValue) in raw {
            guard let key = StudioParameterKey(rawValue: rawKey), let value = Self.value(rawValue) else { continue }
            overrides[key] = value
        }
        let clean = sanitized(overrides)
        return clean.isEmpty ? nil : clean
    }

    private static func parameter(_ raw: [String: Any], key: StudioParameterKey) -> StudioParameter? {
        let label = ((raw["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
            ?? key.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        let help = (raw["help"] as? String).map { String($0.prefix(300)) }
        let options = (raw["options"] as? [Any])?.compactMap(value).prefix(40).map { $0 }
        var control = (raw["control"] as? String).flatMap(StudioParameter.Control.init) ?? .stepper
        if let options, !options.isEmpty {
            control = .choice
        } else if control == .choice {
            control = key.valueType == .text ? .text : .stepper
        }
        if key.valueType == .text, control != .choice { control = .text }
        if key.valueType != .text, control == .text { control = .stepper }

        var minimum = (raw["min"] as? NSNumber)?.doubleValue
        var maximum = (raw["max"] as? NSNumber)?.doubleValue
        if let bounds = key.bounds {
            minimum = min(bounds.upperBound, max(bounds.lowerBound, minimum ?? bounds.lowerBound))
            maximum = min(bounds.upperBound, max(bounds.lowerBound, maximum ?? bounds.upperBound))
            if let low = minimum, let high = maximum, low > high { (minimum, maximum) = (high, low) }
        } else {
            (minimum, maximum) = (nil, nil)
        }
        var step = ((raw["step"] as? NSNumber)?.doubleValue).flatMap { $0 > 0 ? $0 : nil }
        if key.valueType == .integer { step = max(1, (step ?? 1).rounded()) }

        var parameter = StudioParameter(key: key, label: label, help: help, control: control,
                                        minimum: minimum, maximum: maximum, step: step,
                                        options: control == .choice ? options : nil,
                                        defaultValue: .text(""))
        let fallback: StudioValue = parameter.options?.first
            ?? (key.valueType == .text ? .text("") : .number(minimum ?? 0))
        parameter.defaultValue = value(raw["default"]).flatMap(parameter.sanitize) ?? fallback
        return parameter
    }

    private static func value(_ raw: Any?) -> StudioValue? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return .number(number.doubleValue) }
        if let text = raw as? String { return .text(text) }
        return nil
    }

    /// The first JSON object in a reply, tolerating code fences and prose around it.
    static func jsonObject(in reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(reply[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension StudioModelConfig {
    private enum CodingKeys: String, CodingKey {
        case modelID, kind, parameters, values, mode, summary, generatedBy, generatedAt
    }

    /// Values are stored by raw key so unknown keys from newer versions don't fail the decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        kind = try container.decode(LocalStudioKind.self, forKey: .kind)
        parameters = (try? container.decode([LossyParameter].self, forKey: .parameters))?.compactMap(\.value) ?? []
        let rawValues = try container.decodeIfPresent([String: StudioValue].self, forKey: .values) ?? [:]
        values = Dictionary(uniqueKeysWithValues: rawValues.compactMap { key, value in
            StudioParameterKey(rawValue: key).map { ($0, value) }
        })
        mode = (try? container.decode(Mode.self, forKey: .mode)) ?? .manual
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        generatedBy = try container.decodeIfPresent(String.self, forKey: .generatedBy)
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(kind, forKey: .kind)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }), forKey: .values)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(generatedBy, forKey: .generatedBy)
        try container.encode(generatedAt, forKey: .generatedAt)
    }

    private struct LossyParameter: Decodable {
        let value: StudioParameter?
        init(from decoder: Decoder) throws { value = try? StudioParameter(from: decoder) }
    }
}

// MARK: - Applying to the engines' settings

extension VideoGenerationSettings {
    /// `values` override the preset; the result is a custom setting.
    public func applying(_ values: [StudioParameterKey: StudioValue]) -> Self {
        guard !values.isEmpty else { return self }
        var settings = self
        settings.quality = .custom
        for (key, value) in values {
            guard let number = value.number.map({ Int($0) }) else { continue }
            switch key {
            case .width: settings.width = number
            case .height: settings.height = number
            case .steps: settings.steps = number
            case .frames: settings.frames = number
            case .fps: settings.fps = number
            case .seed: settings.seed = number
            default: break
            }
        }
        return settings.validated
    }
}

extension ImageGenerationSettings {
    /// `values` override the preset. Steps and guidance only apply to a
    /// custom setting, so the result is custom.
    public func applying(_ values: [StudioParameterKey: StudioValue]) -> Self {
        guard !values.isEmpty else { return self }
        var settings = self
        settings.quality = .custom
        for (key, value) in values {
            switch key {
            case .width: value.number.map { settings.width = Int($0) }
            case .height: value.number.map { settings.height = Int($0) }
            case .steps: value.number.map { settings.steps = Int($0) }
            case .guidance: settings.cfgScale = value.number
            case .seed: value.number.map { settings.seed = Int($0) }
            case .refineStrength: value.number.map { settings.refineStrength = $0 }
            case .negativePrompt: value.text.map { settings.negativePrompt = $0 }
            default: break
            }
        }
        return settings.validated
    }
}

extension AudioGenerationSettings {
    public func applying(_ values: [StudioParameterKey: StudioValue]) -> Self {
        guard !values.isEmpty else { return self }
        var settings = self
        for (key, value) in values {
            switch key {
            case .temperature:
                value.number.map { settings.temperature = $0 }
                settings.delivery = .custom
            case .voice: value.text.map { settings.voice = $0 }
            case .language: value.text.map { settings.language = $0 }
            case .maxTokens: value.number.map { settings.maxTokens = Int($0) }
            case .seed: value.number.map { settings.seed = Int($0) }
            case .transcriptionInstruction: value.text.map { settings.transcriptionInstruction = $0 }
            default: break
            }
        }
        return settings.validated
    }
}
