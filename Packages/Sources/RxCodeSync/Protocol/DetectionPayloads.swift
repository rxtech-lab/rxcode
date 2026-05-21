import Foundation
import RxCodeCore

/// Mobile → desktop: ask the desktop to scan a project for runnable Xcode
/// schemes, npm scripts, and Make targets. Detection runs `xcodebuild -list`
/// and parses project files, so it stays on the desktop and is requested on
/// demand rather than carried in every snapshot.
public struct RunnableDetectRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID

    public init(clientRequestID: UUID = UUID(), projectID: UUID) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
    }
}

/// Desktop → mobile: the result of a `RunnableDetectRequestPayload`. `detected`
/// is `nil` when `ok` is `false`.
public struct RunnableDetectResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let ok: Bool
    public let errorMessage: String?
    public let detected: DetectedRunnables?

    public init(
        clientRequestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        detected: DetectedRunnables? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.ok = ok
        self.errorMessage = errorMessage
        self.detected = detected
    }
}
