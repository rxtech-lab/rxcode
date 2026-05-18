import RxCodeCore
import SwiftUI

struct EmptyProjectStateView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var briefings: [BranchBriefingItem] {
        _ = appState.branchBriefingRevision
        return appState.threadStore.allBranchBriefingItems()
    }

    private var projectsById: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "sparkle")
                        .font(.system(size: ClaudeTheme.size(48)))
                        .foregroundStyle(ClaudeTheme.accent)

                    Text("Select a Project")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)

                    Text("Select a project from the sidebar or add a new one.")
                        .font(.subheadline)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .padding(.top, 60)

                let items = briefings.compactMap { item -> (BranchBriefingItem, Project)? in
                    guard let project = projectsById[item.projectId] else { return nil }
                    return (item, project)
                }

                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ClaudeTheme.accent)
                            Text("Recent Briefings")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                        }
                        .padding(.horizontal, 4)

                        VStack(spacing: 10) {
                            ForEach(items, id: \.0.id) { item, project in
                                briefingBanner(item: item, project: project)
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 40)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(ClaudeTheme.background)
    }

    private func briefingBanner(item: BranchBriefingItem, project: Project) -> some View {
        Button {
            appState.selectProject(project, in: windowState)
            windowState.showingBriefing = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                        Text(item.branch)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(ClaudeTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(ClaudeTheme.accent.opacity(0.12))
                    )

                    Spacer(minLength: 8)

                    Text(Self.compactDate(item.updatedAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Text(Self.previewText(item.briefing))
                    .font(.system(size: 12.5))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                    .fill(ClaudeTheme.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                    .strokeBorder(ClaudeTheme.border.opacity(0.55), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
    }

    private static func compactDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private static func previewText(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                while s.hasPrefix("#") { s.removeFirst() }
                if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
                    s.removeFirst(2)
                }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
