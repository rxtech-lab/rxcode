import Foundation

public extension CodingPlanActivity {
    var planningStatusLabel: String {
        switch planningStatus {
        case "drafting": "Drafting"
        case "ready": "Ready"
        case "approved": "Approved"
        case "interrupted": "Interrupted"
        default: "Unknown"
        }
    }

    var implementationStatusLabel: String {
        switch implementationStatus {
        case "unimplemented": "Unimplemented"
        case "in_progress": "In progress"
        case "implemented": "Implemented"
        default: "Unknown"
        }
    }

    var versionLabel: String {
        guard versionCount > 0 else { return "No saved version" }
        let number = "v\(versionCount)"
        let latest = currentVersionTitle.map { "\(number) · \($0)" } ?? number
        if let approvedVersionID, approvedVersionID != currentVersionID {
            return "\(latest) · Approved: \(approvedVersionTitle ?? approvedVersionID.uuidString)"
        }
        return latest
    }

    var briefingDescription: String {
        "Plan: \(planningStatusLabel) · Implementation: \(implementationStatusLabel) · \(versionLabel)"
    }
}
