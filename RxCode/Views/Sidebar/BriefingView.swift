import SwiftUI
import Foundation
import RxCodeCore
import WaterfallGrid

struct BriefingView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    /// Selected project ids for filtering. Empty = show every project.
    @State private var selectedProjectIds: Set<UUID> = []

    /// When false (default), only show briefings for each project's current branch.
    @State private var showAllBranches: Bool = false

    /// Cached current branch per project path, refreshed when the project list changes.
    @State private var currentBranchByProject: [UUID: String] = [:]
    @State private var branchRefreshTask: Task<Void, Never>?

    /// Group id whose copy button most recently fired; used for transient checkmark feedback.
    @State private var recentlyCopiedGroupId: String?

    /// Container width tracked from the scroll content; drives the waterfall column count.
    @State private var availableWidth: CGFloat = 800

    private struct BriefingGroup: Identifiable {
        let projectId: UUID
        let branch: String
        let briefing: BranchBriefingItem?
        let threadSummaries: [ThreadSummaryItem]
        let updatedAt: Date
        var id: String { "\(projectId.uuidString)::\(branch)" }
    }

    private var projectsById: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0) })
    }

    private var groups: [BriefingGroup] {
        _ = appState.branchBriefingRevision
        _ = appState.threadSummaryRevision

        let briefings = appState.threadStore.allBranchBriefingItems()
        let summaries = appState.threadStore.allThreadSummaryItems()

        struct Bucket {
            var projectId: UUID
            var branch: String
            var briefing: BranchBriefingItem?
            var threads: [ThreadSummaryItem]
            var updated: Date
        }

        var bucket: [String: Bucket] = [:]
        for b in briefings {
            let key = "\(b.projectId.uuidString)::\(b.branch)"
            var entry = bucket[key] ?? Bucket(projectId: b.projectId, branch: b.branch, briefing: nil, threads: [], updated: .distantPast)
            entry.briefing = b
            if b.updatedAt > entry.updated { entry.updated = b.updatedAt }
            bucket[key] = entry
        }
        for s in summaries {
            let key = "\(s.projectId.uuidString)::\(s.branch)"
            var entry = bucket[key] ?? Bucket(projectId: s.projectId, branch: s.branch, briefing: nil, threads: [], updated: .distantPast)
            entry.threads.append(s)
            if s.updatedAt > entry.updated { entry.updated = s.updatedAt }
            bucket[key] = entry
        }

        let all = bucket.values
            .map {
                BriefingGroup(
                    projectId: $0.projectId,
                    branch: $0.branch,
                    briefing: $0.briefing,
                    threadSummaries: $0.threads.sorted { $0.updatedAt > $1.updatedAt },
                    updatedAt: $0.updated
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let projectFiltered: [BriefingGroup]
        if selectedProjectIds.isEmpty {
            projectFiltered = all
        } else {
            projectFiltered = all.filter { selectedProjectIds.contains($0.projectId) }
        }

        if showAllBranches {
            return projectFiltered
        }
        return projectFiltered.filter { group in
            guard let branch = currentBranchByProject[group.projectId] else {
                // Branch not yet resolved — keep the group so the user isn't shown
                // an empty state while git is still being queried.
                return true
            }
            return group.branch == branch
        }
    }

    /// Projects that actually have at least one briefing or summary recorded.
    private var projectsWithData: [Project] {
        _ = appState.branchBriefingRevision
        _ = appState.threadSummaryRevision
        let ids = Set(
            appState.threadStore.allBranchBriefingItems().map(\.projectId)
            + appState.threadStore.allThreadSummaryItems().map(\.projectId)
        )
        return appState.projects.filter { ids.contains($0.id) }
    }

    var body: some View {
        Group {
            if hasAnyData {
                content
            } else {
                emptyState(
                    icon: "text.page",
                    title: "No Briefings Yet",
                    message: "Briefings appear after a thread finishes on a project branch."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ClaudeTheme.background)
        .task(id: projectPathsKey) {
            await refreshCurrentBranches()
        }
    }

    /// True when there is at least one briefing or thread summary persisted, regardless
    /// of the active filters. Used to decide whether the filter bar should be shown.
    private var hasAnyData: Bool {
        _ = appState.branchBriefingRevision
        _ = appState.threadSummaryRevision
        return !appState.threadStore.allBranchBriefingItems().isEmpty
            || !appState.threadStore.allThreadSummaryItems().isEmpty
    }

    private var projectPathsKey: String {
        appState.projects
            .map { "\($0.id.uuidString):\($0.path)" }
            .joined(separator: "|")
    }

    private func refreshCurrentBranches() async {
        var resolved: [UUID: String] = [:]
        for project in appState.projects {
            if let branch = await GitHelper.currentBranch(at: project.path) {
                resolved[project.id] = branch
            }
        }
        await MainActor.run {
            currentBranchByProject = resolved
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                filterBar

                if groups.isEmpty {
                    filteredEmptyState
                } else {
                    waterfall
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size.width, initial: true) { _, newValue in
                            availableWidth = newValue
                        }
                }
            )
        }
    }

    private var waterfall: some View {
        WaterfallGrid(groups) { group in
            groupCard(group)
        }
        .gridStyle(
            columns: max(1, min(4, Int(availableWidth / 420))),
            spacing: 16,
            animation: .easeInOut(duration: 0.25)
        )
        .scrollOptions(direction: .vertical)
    }

    private var filteredEmptyState: some View {
        let message = showAllBranches
            ? "No briefings match the selected projects."
            : "No briefings for the current branch. Switch to All branches to see other branches."
        return emptyState(
            icon: "line.3.horizontal.decrease.circle",
            title: "Nothing to Show",
            message: message
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.14))
                    Image(systemName: "text.page")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Briefings")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text(heroSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var heroSubtitle: String {
        let count = groups.count
        let branches = count == 1 ? "branch" : "branches"
        let projectCount = Set(groups.map(\.projectId)).count
        let projects = projectCount == 1 ? "project" : "projects"
        if selectedProjectIds.isEmpty {
            return "\(count) \(branches) across \(projectCount) \(projects)."
        }
        return "\(count) \(branches) across \(projectCount) selected \(projects)."
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        let projects = projectsWithData
        return HStack(spacing: 8) {
            branchScopeChip
            projectFilterMenu(projects: projects)
            Spacer(minLength: 0)
        }
    }

    private var branchScopeChip: some View {
        Menu {
            Button {
                showAllBranches = false
            } label: {
                menuSelectionLabel("Current branch", isSelected: !showAllBranches)
            }
            Button {
                showAllBranches = true
            } label: {
                menuSelectionLabel("All branches", isSelected: showAllBranches)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAllBranches ? "arrow.triangle.branch" : "arrow.triangle.branch.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(showAllBranches ? "All branches" : "Current branch")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(showAllBranches ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(showAllBranches ? ClaudeTheme.accent : ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        showAllBranches
                            ? ClaudeTheme.accent.opacity(0.4)
                            : ClaudeTheme.border.opacity(0.6),
                        lineWidth: 0.5
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which branches to show briefings for.")
    }

    @ViewBuilder
    private func projectFilterMenu(projects: [Project]) -> some View {
        if projects.count > 1 {
            Menu {
                    Button {
                        selectedProjectIds.removeAll()
                    } label: {
                        menuSelectionLabel("All projects", isSelected: selectedProjectIds.isEmpty)
                    }
                    Divider()
                    ForEach(projects) { project in
                        Button {
                            toggleProject(project.id)
                        } label: {
                            menuSelectionLabel(project.name, isSelected: selectedProjectIds.contains(project.id))
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(filterMenuLabel(projects: projects))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(selectedProjectIds.isEmpty ? ClaudeTheme.textSecondary : ClaudeTheme.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedProjectIds.isEmpty ? ClaudeTheme.surfaceSecondary : ClaudeTheme.accent)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                selectedProjectIds.isEmpty
                                    ? ClaudeTheme.border.opacity(0.6)
                                    : ClaudeTheme.accent.opacity(0.4),
                                lineWidth: 0.5
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func filterMenuLabel(projects: [Project]) -> String {
        if selectedProjectIds.isEmpty {
            return "All projects"
        }
        if selectedProjectIds.count == 1, let id = selectedProjectIds.first {
            return projectsById[id]?.name ?? "1 project"
        }
        return "\(selectedProjectIds.count) projects"
    }

    private func toggleProject(_ id: UUID) {
        if selectedProjectIds.contains(id) {
            selectedProjectIds.remove(id)
        } else {
            selectedProjectIds.insert(id)
        }
    }

    // MARK: - Group card

    private func groupCard(_ group: BriefingGroup) -> some View {
        let project = projectsById[group.projectId]
        return VStack(alignment: .leading, spacing: 12) {
            groupCardHeader(group, project: project)

            if let briefing = group.briefing {
                Divider().opacity(0.4)
                BriefingMarkdownView(text: briefing.briefing, fontSize: 12.5)
            }

            if !group.threadSummaries.isEmpty {
                Divider().opacity(0.4)
                threadList(group.threadSummaries)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
    }

    private func groupCardHeader(_ group: BriefingGroup, project: Project?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ClaudeTheme.accent.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project?.name ?? "Unknown project")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    chip(icon: "arrow.triangle.branch", text: group.branch, accented: true)
                }
                Text("Updated \(Self.compactDate(group.updatedAt))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Spacer(minLength: 0)

            copyButton(for: group)

            if let project {
                cardMenu(for: project)
            }
        }
    }

    private func copyButton(for group: BriefingGroup) -> some View {
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

    private func copyBriefing(_ group: BriefingGroup) {
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

    private func renderBriefingText(_ group: BriefingGroup) -> String {
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

    private func cardMenu(for project: Project) -> some View {
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
        .help("Actions for \(project.name)")
    }

    private func chip(icon: String, text: String, accented: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(accented ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(accented ? ClaudeTheme.accent.opacity(0.12) : ClaudeTheme.surfaceSecondary)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(accented ? ClaudeTheme.accent.opacity(0.25) : ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - Thread list (compact rows)

    private func threadList(_ items: [ThreadSummaryItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Threads")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("\(items.count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ClaudeTheme.surfaceSecondary))
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(items) { item in
                threadRow(item)
            }
        }
    }

    private func threadRow(_ item: ThreadSummaryItem) -> some View {
        Button {
            appState.selectSession(id: item.sessionId, in: windowState)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                    .frame(width: 14)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Self.compactDate(item.updatedAt))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ClaudeTheme.surfaceSecondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .help("Open thread")
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(ClaudeTheme.surfaceSecondary)
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 60)
    }

    private static func compactDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: - Lightweight Markdown Renderer

/// Renders simple markdown content (bullets, ordered lists, paragraphs, headings, inline
/// bold/italic/code). Designed for compact briefings/summaries — not a full markdown engine.
private struct BriefingMarkdownView: View {
    let text: String
    var fontSize: CGFloat = 13.5

    private var blocks: [Block] {
        Self.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(Self.inline(content))
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                case .paragraph(let content):
                    Text(Self.inline(content))
                        .font(.system(size: fontSize))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullet(let content):
                    bulletRow(marker: "•", content: content)
                case .ordered(let number, let content):
                    bulletRow(marker: "\(number).", content: content, monospaced: true)
                }
            }
        }
    }

    private func bulletRow(marker: String, content: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(monospaced
                      ? .system(size: fontSize, weight: .semibold).monospacedDigit()
                      : .system(size: fontSize, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(minWidth: 14, alignment: .leading)
            Text(Self.inline(content))
                .font(.system(size: fontSize))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 5
        case 2: return fontSize + 3
        case 3: return fontSize + 2
        default: return fontSize + 1
        }
    }

    // MARK: Parsing

    enum Block {
        case heading(level: Int, content: String)
        case paragraph(String)
        case bullet(String)
        case ordered(number: Int, content: String)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }

            // Heading: # to ######
            if line.hasPrefix("#") {
                var level = 0
                for ch in line {
                    if ch == "#" { level += 1 } else { break }
                }
                if level >= 1, level <= 6, line.count > level,
                   line[line.index(line.startIndex, offsetBy: level)] == " " {
                    flushParagraph()
                    let content = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, content: content))
                    continue
                }
            }

            // Unordered bullet
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }

            // Ordered list "1. content"
            if let dotIdx = line.firstIndex(of: "."),
               let number = Int(line[line.startIndex..<dotIdx]),
               line.index(after: dotIdx) < line.endIndex,
               line[line.index(after: dotIdx)] == " " {
                flushParagraph()
                let content = String(line[line.index(dotIdx, offsetBy: 2)...])
                blocks.append(.ordered(number: number, content: content))
                continue
            }

            paragraphBuffer.append(line)
        }

        flushParagraph()
        return blocks
    }

    private static func inline(_ content: String) -> AttributedString {
        if var attr = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Style inline code spans
            for run in attr.runs {
                guard let intent = run.inlinePresentationIntent else { continue }
                if intent.contains(.code) {
                    attr[run.range].font = .system(size: 12.5, design: .monospaced)
                    attr[run.range].foregroundColor = ClaudeTheme.textPrimary
                    attr[run.range].backgroundColor = ClaudeTheme.surfaceTertiary
                }
            }
            return attr
        }
        return AttributedString(content)
    }
}
