import SwiftUI
import RxCodeCore

/// Per-branch pull-request status shown on a briefing card: a chip reflecting the
/// branch's PR state (merged / open / closed) that links to the PR, or a
/// "Create PR" button when no PR exists yet. Status is read from
/// `AppState.ciStatusByBranchKey`, which the CI poller maintains for every
/// briefing branch (not just current branches).
struct BriefingPRStatusView: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID
    let branch: String
    let project: Project?

    @State private var inFlight = false
    @State private var prError: PRErrorAlert?

    private struct PRErrorAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    var body: some View {
        let _ = appState.ciStatusRevision
        let status = appState.ciStatus(forProjectId: projectId, branch: branch)
        Group {
            if let prState = status?.pullRequestState {
                prChip(state: prState, status: status)
            } else if let project, project.gitHubRepo != nil {
                createPRButton(project: project)
            }
        }
        .alert(item: $prError) { error in
            Alert(
                title: Text("Couldn't Create Pull Request"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
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
            startCreatePR(project: project)
        } label: {
            HStack(spacing: 4) {
                if inFlight {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(inFlight ? "Creating…" : "Create PR")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(ClaudeTheme.accent))
        }
        .buttonStyle(.plain)
        .disabled(inFlight)
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

    private func startCreatePR(project: Project) {
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let url = try await appState.createPullRequestForBranch(
                    project: project,
                    branch: branch
                )
                NSWorkspace.shared.open(url)
            } catch {
                prError = PRErrorAlert(message: error.localizedDescription)
            }
        }
    }
}
