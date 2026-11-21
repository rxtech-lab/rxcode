import RxCodeCore
import SwiftUI

/// Remembers which pushed branches the user already acted on or dismissed, so
/// the toolbar tip appears once per branch instead of on every window open.
enum GitPullRequestTipLedger {
    private static let defaultsKey = "gitPullRequestTipDismissedBranches"
    private static let limit = 200

    private static func key(for target: GitPullRequestTarget) -> String {
        "\(target.repository.lowercased())#\(target.branch)"
    }

    static func isDismissed(_ target: GitPullRequestTarget) -> Bool {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains(key(for: target))
    }

    static func dismiss(_ target: GitPullRequestTarget) {
        var keys = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        let key = key(for: target)
        guard !keys.contains(key) else { return }
        keys.append(key)
        UserDefaults.standard.set(Array(keys.suffix(limit)), forKey: defaultsKey)
    }
}

/// Tip shown under the toolbar "Create PR" button when the current branch is
/// pushed but has no pull request.
struct GitPullRequestTipView: View {
    let branch: String
    let onCreate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 20, weight: .semibold))
                .themedAccentInk()
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready for a pull request?")
                    .font(.headline)
                Text("“\(branch)” is pushed but has no pull request yet. An agent can draft the title and description for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Not Now", action: onDismiss)
                    Button("Create Pull Request…", action: onCreate)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Compact "PR" control on the current branch's sidebar row: opens the create
/// sheet, or picks the agent that drafts the title and description.
struct GitSidebarPullRequestButton: View {
    let target: GitPullRequestTarget
    let onCreate: () -> Void

    var body: some View {
        Menu {
            Button("Create Pull Request…", systemImage: "arrow.triangle.pull", action: onCreate)
            Menu {
                PullRequestDraftModelMenuContent { _ in onCreate() }
            } label: {
                Label("Draft with Agent", systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .semibold))
                Text("Create PR")
                    .font(.system(size: ClaudeTheme.size(10.5), weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(ClaudeTheme.textOnAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(ClaudeTheme.accent))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("“\(target.branch)” is pushed but has no pull request. Create one with an agent-drafted title and description.")
        .accessibilityIdentifier("git-create-pr-sidebar")
    }
}
