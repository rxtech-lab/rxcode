import Foundation

public enum RunStepType: String, Codable, Sendable, CaseIterable, Hashable {
    case bash
}

public struct RunStep: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var type: RunStepType
    public var command: String

    public init(id: UUID = UUID(), type: RunStepType = .bash, command: String = "") {
        self.id = id
        self.type = type
        self.command = command
    }
}
