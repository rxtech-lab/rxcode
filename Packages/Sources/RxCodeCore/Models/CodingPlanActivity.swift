import Foundation

/// A coding debate and the completion evidence for its implementation chats.
public struct CodingPlanActivity: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let threadID: String
    public let projectID: UUID
    public let title: String
    public let goal: String
    public let branch: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let planningStatus: String
    public let implementationStatus: String
    public let implementationEvidence: String
    public let implementationThreadID: String?
    public let implementationThreadIDs: [String]?
    public var linkedImplementationIDs: [String] { implementationThreadIDs ?? [implementationThreadID].compactMap { $0 } }
    public let currentVersionID: UUID?
    public let currentVersionTitle: String?
    public let approvedVersionID: UUID?
    public let approvedVersionTitle: String?
    public let versionCount: Int
    public let featureExcerpt: String

    public init(id: UUID, threadID: String, projectID: UUID, title: String, goal: String,
                branch: String?, createdAt: Date, updatedAt: Date, planningStatus: String,
                implementationStatus: String, implementationEvidence: String,
                implementationThreadID: String?, currentVersionID: UUID?, currentVersionTitle: String?,
                approvedVersionID: UUID?, versionCount: Int, featureExcerpt: String, approvedVersionTitle: String? = nil,
                implementationThreadIDs: [String]? = nil) {
        self.id = id
        self.threadID = threadID
        self.projectID = projectID
        self.title = title
        self.goal = goal
        self.branch = branch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.planningStatus = planningStatus
        self.implementationStatus = implementationStatus
        self.implementationEvidence = implementationEvidence
        self.implementationThreadID = implementationThreadID
        self.implementationThreadIDs = implementationThreadIDs
        self.currentVersionID = currentVersionID
        self.currentVersionTitle = currentVersionTitle
        self.approvedVersionID = approvedVersionID
        self.approvedVersionTitle = approvedVersionTitle
        self.versionCount = versionCount
        self.featureExcerpt = featureExcerpt
    }
}
