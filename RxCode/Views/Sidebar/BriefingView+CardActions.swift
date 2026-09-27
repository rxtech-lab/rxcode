import SwiftUI
import Foundation
import RxCodeCore

// MARK: - Group card actions

extension BriefingView {
    func copyButton(for group: BriefingGroup) -> some View {
        let copied = recentlyCopiedGroupId == group.id
        return Button {
            copyBriefing(group)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ClaudeTheme.surfaceSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy briefing text")
        .disabled(group.briefing == nil && group.threadSummaries.isEmpty)
    }

    func copyBriefing(_ group: BriefingGroup) {
        let text = renderBriefingText(group)
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let id = group.id
        recentlyCopiedGroupId = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if recentlyCopiedGroupId == id {
                recentlyCopiedGroupId = nil
            }
        }
    }

    func renderBriefingText(_ group: BriefingGroup) -> String {
        var lines: [String] = []
        let projectName = projectsById[group.projectId]?.name ?? "Unknown project"
        lines.append("# \(projectName) — \(group.branch)")
        lines.append("")

        if let briefing = group.briefing {
            lines.append(briefing.briefing.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        if !group.threadSummaries.isEmpty {
            lines.append("## Threads")
            for thread in group.threadSummaries {
                lines.append("- \(thread.title)")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GitHub destination for a briefing card's "Open on GitHub" action. Prefers
    /// the pull request associated with the branch (mirroring the menu bar
    /// extra), and falls back to the repository page when no PR is known.
    func gitHubURL(for group: BriefingGroup, project: Project) -> URL? {
        let _ = appState.ciStatusRevision
        if currentBranchByProject[group.projectId] == group.branch,
           let status = appState.ciStatusByProject[group.projectId],
           let prNumber = status.prNumber {
            return URL(string: "https://github.com/\(status.owner)/\(status.repo)/pull/\(prNumber)")
        }
        guard let ownerRepo = project.gitHubRepo else { return nil }
        return gitHubWebURL(forOwnerRepo: ownerRepo)
    }

    /// True when the GitHub action for this card points at a pull request.
    func gitHubURLIsPullRequest(for group: BriefingGroup) -> Bool {
        let _ = appState.ciStatusRevision
        return currentBranchByProject[group.projectId] == group.branch
            && appState.ciStatusByProject[group.projectId]?.prNumber != nil
    }

    /// Start a `[Code Review]` thread reviewing the whole branch (grounded in
    /// its briefing) and open it, mirroring the project/thread review menus.
    func startCodeReview(for group: BriefingGroup, project: Project) {
        Task {
            if windowState.selectedProject?.id != project.id {
                appState.selectProject(project, in: windowState)
            }
            if let threadId = try? await appState.createCodeReviewForBranch(project: project, branch: group.branch) {
                appState.selectSession(id: threadId, in: windowState)
            }
        }
    }

    /// Start a commit-only thread for all current project changes and open it.
    func startCommitAll(for project: Project) {
        Task {
            if windowState.selectedProject?.id != project.id {
                appState.selectProject(project, in: windowState)
            }
            if let threadId = try? await appState.commitAllChangesForProject(project: project) {
                appState.selectSession(id: threadId, in: windowState)
            }
        }
    }

    func cardMenu(for group: BriefingGroup, project: Project) -> some View {
        Menu {
            Button {
                if windowState.selectedProject?.id != project.id {
                    appState.selectProject(project, in: windowState)
                }
                appState.startNewChat(in: windowState)
            } label: {
                Label("Start New Chat", systemImage: "plus.bubble.fill")
            }

            Button {
                if windowState.selectedProject?.id != project.id {
                    appState.selectProject(project, in: windowState)
                }
            } label: {
                Label("Open Project", systemImage: "folder")
            }

            Divider()

            let handler = appState.desktopMenuActionHandler { threadId in
                appState.selectSession(id: threadId, in: windowState)
            }

            // The briefing card represents one branch, so it asks the hooks for a
            // branch-scoped menu: Code Review / Create PR target `group.branch`,
            // followed by the project's autopilot setup items. All hook-built — no
            // items assembled in the view.
            let items = appState.projectContextMenuItems(for: project, branch: group.branch)
            if !items.isEmpty {
                MenuItemsView(items)
                    .menuActionHandler(handler)
            }

            if let url = gitHubURL(for: group, project: project) {
                Divider()
                Link(destination: url) {
                    Label(
                        gitHubURLIsPullRequest(for: group) ? "Open Pull Request" : "Open on GitHub",
                        systemImage: "arrow.up.forward.square"
                    )
                }
            }

            if group.briefing != nil && presentedBriefing == nil {
                Divider()
                Button(role: .destructive) {
                    briefingToDelete = group
                } label: {
                    Label("Delete Briefing", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ClaudeTheme.surfaceSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("briefing-group-actions-button")
        .help("Actions for \(project.name)")
    }

    /// CI status chip, shown only on the card matching the project's current
    /// branch (CI status is tracked per project for its current branch). Failing
    /// states link to the failing run on GitHub.
    @ViewBuilder
    func ciChip(for group: BriefingGroup) -> some View {
        let _ = appState.ciStatusRevision
        if currentBranchByProject[group.projectId] == group.branch,
           let status = appState.ciStatusByProject[group.projectId] {
            let state = status.overallState
            if state == .failure,
               let urlString = status.failing.first?.htmlUrl,
               let url = URL(string: urlString) {
                Link(destination: url) {
                    ciChipLabel(state: state)
                }
                .buttonStyle(.plain)
                .help("CI failing — open the failing run on GitHub")
            } else {
                ciChipLabel(state: state)
            }
        }
    }

    func ciChipLabel(state: CIOverallState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.sfSymbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(state.label)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(state.displayColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(state.displayColor.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(state.displayColor.opacity(0.25), lineWidth: 0.5)
        )
    }
}
