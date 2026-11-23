import Foundation

/// The current step of a project's board sync. This is transient UI state;
/// the board's last successful sync and error remain in `CloudBoardSyncState`.
enum CloudProjectSyncPhase: Int {
    case fetchingBoard
    case syncingStories
    case syncingTasks
    case publishingFilters
    case savingChanges

    var fractionCompleted: Double { Double(rawValue) / 5 }

    var progressText: String {
        switch self {
        case .fetchingBoard: String(localized: "Fetching cloud board (step 1 of 5)")
        case .syncingStories: String(localized: "Syncing stories (step 2 of 5)")
        case .syncingTasks: String(localized: "Syncing tasks (step 3 of 5)")
        case .publishingFilters: String(localized: "Publishing Swift filters (step 4 of 5)")
        case .savingChanges: String(localized: "Finishing sync (step 5 of 5)")
        }
    }
}
