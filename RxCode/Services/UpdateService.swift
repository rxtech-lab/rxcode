import Sparkle

/// Service that manages Sparkle auto-updates.
/// Automatically checks for updates on app launch; users can also check manually from the menu.
@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
