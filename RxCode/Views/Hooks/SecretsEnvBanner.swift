import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Banner shown on the new-project screen when a project has a local `.env*`
/// file that isn't backed up to autopilot (or the repo has no secrets set up).
/// Built by `AutopilotHook` and rendered via `HookBannerHost`. The
/// "Set up" button opens the secrets deep link, which `MainWindowRoot` routes
/// to the secret-setup form.
struct SecretsEnvBanner: View {
    let repo: String
    let projectPath: String?
    /// The missing file (e.g. `.env`), or nil when the repo has no secrets at all.
    let missingFile: String?
    /// Called when the user taps the close button. The hook persists the
    /// dismissal so the banner won't reappear.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    private var message: String {
        if let missingFile {
            return String(format: String(localized: "%@ isn't backed up to Autopilot"), missingFile)
        }
        return String(localized: "Back up this project's secrets to Autopilot")
    }

    var body: some View {
        HookBannerRow(
            icon: "key.fill",
            message: message,
            onTap: open,
            onDismiss: onDismiss
        )
    }

    private func open() {
        guard let url = SecretsDeepLink.addURL(repo: repo, path: projectPath, file: missingFile) else { return }
        openURL(url)
    }
}
