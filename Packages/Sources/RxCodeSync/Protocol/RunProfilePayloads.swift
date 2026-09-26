import Foundation
import RxCodeCore

// MARK: - Run profile payloads

public struct MobileProjectRunProfiles: Codable, Sendable, Equatable {
    public let projectId: UUID
    public let profiles: [RunProfile]

    public init(projectId: UUID, profiles: [RunProfile]) {
        self.projectId = projectId
        self.profiles = profiles
    }
}

public struct MobileRunTaskSnapshot: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case signaled
        case stopped
    }

    public var id: UUID { taskId }

    public let taskId: UUID
    public let projectId: UUID
    public let profileId: UUID
    public let profileName: String
    public let status: Status
    public let statusLabel: String
    public let exitCode: Int32?
    public let startedAt: Date
    public let resolvedCwd: String
    public let commandPreview: String
    public let terminalOutputTail: String?

    public init(
        taskId: UUID,
        projectId: UUID,
        profileId: UUID,
        profileName: String,
        status: Status,
        statusLabel: String,
        exitCode: Int32? = nil,
        startedAt: Date,
        resolvedCwd: String,
        commandPreview: String,
        terminalOutputTail: String? = nil
    ) {
        self.taskId = taskId
        self.projectId = projectId
        self.profileId = profileId
        self.profileName = profileName
        self.status = status
        self.statusLabel = statusLabel
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.resolvedCwd = resolvedCwd
        self.commandPreview = commandPreview
        self.terminalOutputTail = terminalOutputTail
    }

    public var isRunning: Bool { status == .running }
}

public struct RunProfileMutationRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case upsert
        case delete
    }

    public let clientRequestID: UUID
    public let projectID: UUID
    public let operation: Operation
    public let profile: RunProfile?
    public let profileID: UUID?

    public init(
        clientRequestID: UUID = UUID(),
        projectID: UUID,
        operation: Operation,
        profile: RunProfile? = nil,
        profileID: UUID? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.profile = profile
        self.profileID = profileID
    }
}

public struct RunProfileRunRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let profileID: UUID

    public init(clientRequestID: UUID = UUID(), projectID: UUID, profileID: UUID) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.profileID = profileID
    }
}

public struct RunProfileStopRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let taskID: UUID?
    public let projectID: UUID?
    public let profileID: UUID?

    public init(
        clientRequestID: UUID = UUID(),
        taskID: UUID? = nil,
        projectID: UUID? = nil,
        profileID: UUID? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.taskID = taskID
        self.projectID = projectID
        self.profileID = profileID
    }
}

public struct RunProfileResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let ok: Bool
    public let errorMessage: String?
    public let profiles: [RunProfile]?
    public let task: MobileRunTaskSnapshot?

    public init(
        clientRequestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        profiles: [RunProfile]? = nil,
        task: MobileRunTaskSnapshot? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.ok = ok
        self.errorMessage = errorMessage
        self.profiles = profiles
        self.task = task
    }
}

public struct RunTaskUpdatePayload: Codable, Sendable {
    public let task: MobileRunTaskSnapshot

    public init(task: MobileRunTaskSnapshot) {
        self.task = task
    }
}
