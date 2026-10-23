import Foundation

nonisolated struct FlowcyPushDestination: Identifiable, Equatable {
    let id = UUID()
    let projectID: String?
    let taskID: String?
    let storyID: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["source"] as? String == "flowcy" else { return nil }
        func identifier(_ key: String) -> String? {
            guard let value = userInfo[key] as? String, !value.isEmpty, value.utf8.count <= 200,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value
        }
        projectID = identifier("projectId")
        taskID = projectID == nil ? nil : identifier("taskId")
        storyID = projectID == nil ? nil : identifier("storyId")
    }
}
