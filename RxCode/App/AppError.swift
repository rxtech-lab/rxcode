import Foundation

// MARK: - App Errors

enum AppError: LocalizedError {
    case noProjectSelected
    case claudeNotInstalled
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectSelected:
            return "No project selected. Please select or add a project first."
        case .claudeNotInstalled:
            return "Claude CLI binary not found. Please install it first."
        case .streamFailed(let message):
            return message
        }
    }
}
