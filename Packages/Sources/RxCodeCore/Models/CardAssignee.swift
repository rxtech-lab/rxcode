import Foundation

/// Public project-member profile returned with a cloud board.
public struct CardAssignee: Codable, Hashable, Sendable, Identifiable {
    public var userId: String
    public var name: String?
    public var email: String?
    public var image: String?
    public var id: String { userId }
    public var displayName: String { name ?? email ?? userId }

    public init(userId: String, name: String? = nil, email: String? = nil, image: String? = nil) {
        self.userId = userId
        self.name = name
        self.email = email
        self.image = image
    }
}

public extension TaskBoard {
    /// A cloud board must supply the viewer's role before allowing edits.
    func canEditCard(assigneeIds: [String], userID: String?) -> Bool {
        guard let cloudSync else { return true }
        guard let userID, cloudSync.currentUserId == userID else { return false }
        return cloudSync.role == "owner" || (cloudSync.role == "member" && assigneeIds.contains(userID))
    }
}
