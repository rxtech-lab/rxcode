import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Banner shown on the new-project screen when a project has local
/// `.github/workflows/*.yml|yaml` files but its repo isn't yet watched for CI
/// auto-updates. Built by `CIUpdateHook` and rendered via `HookBannerHost`. The
/// "Set up" button opens the CI deep link, which `MainView` routes to the CI
/// auto-update manage sheet pre-targeted at this repo.
struct CIUpdateBanner: View {
    let repo: String
    let projectPath: String?
    /// Number of local workflow files detected, for the message copy.
    let workflowCount: Int
    /// Called when the user taps the close button. The hook persists the
    /// dismissal so the banner won't reappear.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    private var message: String {
        String(localized: "Keep this repo's GitHub Actions up to date automatically")
    }

    var body: some View {
        HookBannerRow(
            icon: "arrow.triangle.2.circlepath",
            message: message,
            onTap: open,
            onDismiss: onDismiss
        )
    }

    private func open() {
        guard let url = CIUpdateDeepLink.addURL(repo: repo, path: projectPath) else { return }
        openURL(url)
    }
}
