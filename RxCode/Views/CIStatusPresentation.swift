import SwiftUI
import RxCodeCore

/// Shared presentation mapping for GitHub Actions CI state, used by the menubar
/// popover and the briefing cards so the dot color / icon / label stay consistent.
extension CIOverallState {
    var displayColor: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        case .pending: return .yellow
        case .unknown: return .secondary
        }
    }

    var sfSymbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .success: return "Passing"
        case .failure: return "Failing"
        case .pending: return "Running"
        case .unknown: return "No status"
        }
    }
}
