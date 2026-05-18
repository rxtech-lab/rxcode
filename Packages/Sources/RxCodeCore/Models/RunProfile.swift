import Foundation

public enum RunProfileType: String, Codable, Sendable, CaseIterable, Hashable {
    case bash
    case xcode
    case make
}

public struct RunProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var type: RunProfileType
    public var bash: BashRunConfig
    /// Populated when `type == .xcode`. Optional so existing on-disk profiles
    /// (written before the Xcode type existed) decode cleanly.
    public var xcode: XcodeRunConfig?
    /// Populated when `type == .make`. Optional so existing on-disk profiles
    /// (written before the Make type existed) decode cleanly.
    public var make: MakeRunConfig?
    public var beforeSteps: [RunStep]
    public var afterSteps: [RunStep]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        type: RunProfileType = .bash,
        bash: BashRunConfig = BashRunConfig(),
        xcode: XcodeRunConfig? = nil,
        make: MakeRunConfig? = nil,
        beforeSteps: [RunStep] = [],
        afterSteps: [RunStep] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.type = type
        self.bash = bash
        self.xcode = xcode
        self.make = make
        self.beforeSteps = beforeSteps
        self.afterSteps = afterSteps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
