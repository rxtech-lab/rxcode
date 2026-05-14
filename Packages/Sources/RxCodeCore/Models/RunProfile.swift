import Foundation

public enum RunProfileType: String, Codable, Sendable, CaseIterable, Hashable {
    case bash
}

public struct RunProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var type: RunProfileType
    public var bash: BashRunConfig
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
        self.beforeSteps = beforeSteps
        self.afterSteps = afterSteps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
