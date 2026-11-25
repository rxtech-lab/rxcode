import SwiftUI
import RxCodeCore

/// Per-branch pull-request status shown on a briefing card: a chip reflecting the
/// branch's PR state (merged / open / closed) that links to the PR, or a
/// "Create PR" button when no PR exists yet. Status is read from
/// the workspace's branch status snapshot, which the CI poller maintains for every
/// briefing branch (not just current branches).
struct BriefingPRStatusView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let projectId: UUID
    let branch: String
    let project: Project?

    var body: some View {
        let _ = BriefingPerformanceLog.log("PR status body\(BriefingTimelineScrollActivity.isAnyScrolling ? " [scrolling]" : "") \(branch)")
        let _ = appState.ciStatusRevision
        let status = appState.ciStatus(forProjectId: projectId, branch: branch)
        Group {
            if let prState = status?.pullRequestState {
                prChip(state: prState, status: status)
            } else if let project, project.gitHubRepo != nil {
                createPRButton(project: project)
            }
        }
    }

    private func prChip(state: PRState, status: ProjectCIStatus?) -> some View {
        let text: String
        let icon: String
        let color: Color
        switch state {
        case .merged:
            text = "Merged"
            icon = "arrow.triangle.merge"
            color = .purple
        case .open:
            text = status?.prNumber.map { "PR #\($0)" } ?? "PR open"
            icon = "arrow.triangle.pull"
            color = .green
        case .closed:
            text = status?.prNumber.map { "PR #\($0) closed" } ?? "PR closed"
            icon = "xmark"
            color = .red
        }

        return Group {
            if let url = prURL(for: status) {
                Link(destination: url) { prChipLabel(text: text, icon: icon, color: color) }
                    .buttonStyle(.plain)
                    .help("Open pull request on GitHub")
            } else {
                prChipLabel(text: text, icon: icon, color: color)
            }
        }
    }

    private func prChipLabel(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }

    private func createPRButton(project: Project) -> some View {
        Button {
            appState.projectPullRequestRequests[windowState.id] = ProjectPullRequestRequest(project: project, branch: branch)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .semibold))
                Text("Create PR")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(ClaudeTheme.textOnAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(ClaudeTheme.accent))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Push the branch and open a pull request from this briefing")
    }

    /// Destination for a PR chip: the synced PR URL, falling back to a
    /// constructed pull URL from owner/repo/number.
    private func prURL(for status: ProjectCIStatus?) -> URL? {
        guard let status else { return nil }
        if let urlString = status.prUrl, let url = URL(string: urlString) { return url }
        if let number = status.prNumber {
            return URL(string: "https://github.com/\(status.owner)/\(status.repo)/pull/\(number)")
        }
        return nil
    }
}
