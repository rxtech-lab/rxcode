import Foundation

public struct BashRunConfig: Codable, Sendable, Hashable {
    public var command: String
    public var workingDirectory: String
    public var environments: [EnvironmentPreset]
    public var activePresetId: UUID?

    public init(
        command: String = "",
        workingDirectory: String = "",
        environments: [EnvironmentPreset] = [],
        activePresetId: UUID? = nil
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environments = environments
        self.activePresetId = activePresetId
    }
}

public struct EnvironmentPreset: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var loadFromFile: Bool
    public var envFilePath: String?
    public var useManualKV: Bool
    public var manualVars: [EnvVar]

    public init(
        id: UUID = UUID(),
        name: String,
        loadFromFile: Bool = false,
        envFilePath: String? = nil,
        useManualKV: Bool = true,
        manualVars: [EnvVar] = []
    ) {
        self.id = id
        self.name = name
        self.loadFromFile = loadFromFile
        self.envFilePath = envFilePath
        self.useManualKV = useManualKV
        self.manualVars = manualVars
    }
}

public struct EnvVar: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}
