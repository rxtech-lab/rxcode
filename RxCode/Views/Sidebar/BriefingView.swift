import SwiftUI
import Foundation
import RxCodeCore

struct BriefingView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    @State private var currentBranch: String?

    private var project: Project? {
        windowState.selectedProject
    }

    private var briefing: BranchBriefingItem? {
        _ = appState.branchBriefingRevision
        guard let project, let currentBranch else { return nil }
        return appState.threadStore.branchBriefingItem(projectId: project.id, branch: currentBranch)
    }

    private var threadSummaries: [ThreadSummaryItem] {
        _ = appState.threadSummaryRevision
        guard let project, let currentBranch else { return [] }
        return appState.threadStore.threadSummaryItems(projectId: project.id, branch: currentBranch)
    }

    var body: some View {
        Group {
            if let project {
                projectBriefing(project)
            } else {
                emptyState(
                    icon: "folder",
                    title: "Select a Project",
                    message: "Choose a project to view its branch briefing."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ClaudeTheme.background)
        .task(id: project?.path) {
            while !Task.isCancelled {
                await refreshBranch()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func projectBriefing(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero(project)

                if currentBranch == nil {
                    emptyState(
                        icon: "arrow.triangle.branch",
                        title: "No Git Branch",
                        message: "This project does not have a detectable current branch."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else if briefing == nil, threadSummaries.isEmpty {
                    emptyState(
                        icon: "text.page",
                        title: "No Briefing Yet",
                        message: "Briefing updates after a thread finishes on this branch."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    if let briefing {
                        briefingCard(briefing)
                    }

                    if !threadSummaries.isEmpty {
                        threadSection(threadSummaries)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Hero

    private func hero(_ project: Project) -> some View {
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
                    HStack(alignment: .center, spacing: 10) {
                        Text(project.name)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        startNewChatButton(for: project)
                    }
                    Text("A running summary of work on this branch.")
                        .font(.system(size: 12))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                chip(icon: "folder.fill", text: project.name)
                if let currentBranch {
                    chip(icon: "arrow.triangle.branch", text: currentBranch, accented: true)
                } else {
                    chip(icon: "arrow.triangle.branch", text: "No branch")
                }
            }
        }
    }

    private func startNewChatButton(for project: Project) -> some View {
        Button {
            if windowState.selectedProject?.id != project.id {
                appState.selectProject(project, in: windowState)
            }
            appState.startNewChat(in: windowState)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Start New Chat")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textOnAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous).fill(ClaudeTheme.accent)
            )
        }
        .buttonStyle(.plain)
        .help("Start a new chat in \(project.name)")
    }

    private func chip(icon: String, text: String, accented: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(accented ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(accented ? ClaudeTheme.accent.opacity(0.12) : ClaudeTheme.surfaceSecondary)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(accented ? ClaudeTheme.accent.opacity(0.25) : ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - Briefing Card

    private func briefingCard(_ item: BranchBriefingItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("General")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                Text("Updated \(Self.compactDate(item.updatedAt))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            BriefingMarkdownView(text: item.briefing, fontSize: 13.5)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - Thread Summaries

    private func threadSection(_ items: [ThreadSummaryItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Thread Summaries")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(ClaudeTheme.surfaceSecondary)
                    )

                Spacer()
            }
            .padding(.horizontal, 2)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(items) { item in
                    threadCard(item)
                }
            }
        }
    }

    private func threadCard(_ item: ThreadSummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.12))
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 22, height: 22)

                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .opacity(0.4)

            BriefingMarkdownView(text: item.summary, fontSize: 12.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text(Self.compactDate(item.updatedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
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

    private func refreshBranch() async {
        guard let project else {
            await MainActor.run { currentBranch = nil }
            return
        }
        let branch = await GitHelper.currentBranch(at: project.path)
        await MainActor.run {
            currentBranch = branch
            if let branch {
                appState.touchBranchBriefing(projectId: project.id, branch: branch)
            }
        }
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
