import RxCodeCore
import SwiftUI

// MARK: - ChatStatus

/// Per-chat status derived from streaming state, pending permissions, and errors.
public enum ChatStatus: Sendable, Equatable {
    case idle
    case streaming
    case awaitingPermission
    case done
    case error(String)
}

// MARK: - ChatTodoProgress

nonisolated struct ChatTodoProgress: Sendable, Equatable {
    let done: Int
    let total: Int
    let inProgress: Bool

    init(done: Int, total: Int, inProgress: Bool) {
        self.done = done
        self.total = total
        self.inProgress = inProgress
    }

    init(todos: [TodoItem]) {
        self.done = todos.filter { $0.status == .completed }.count
        self.total = todos.count
        self.inProgress = todos.contains { $0.status == .inProgress }
    }
}

// MARK: - StatusBadgeDot

struct StatusBadgeDot: View {
    let status: ChatStatus

    private var color: Color {
        switch status {
        case .idle: return ClaudeTheme.textTertiary.opacity(0.4)
        case .streaming: return ClaudeTheme.accent
        case .awaitingPermission: return Color.yellow
        case .done: return ClaudeTheme.statusSuccess
        case .error: return ClaudeTheme.statusError
        }
    }

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(pulse ? 1.4 : 1.0)
            .opacity(pulse ? 0.65 : 1.0)
            .onAppear { syncPulse() }
            .onDisappear { stopPulse() }
            .onChange(of: shouldPulse) { syncPulse() }
    }

    /// Start or stop the pulse to match `status`.
    ///
    /// Stopping matters as much as starting. A `repeatForever` animation keeps
    /// SwiftUI's display link running for as long as its value stays animated, and
    /// this dot survives an `awaitingPermission` -> `done` transition with the same
    /// view identity — so a pulse started for a permission prompt and never
    /// stopped keeps re-running the whole sidebar `ForEach` every frame, forever,
    /// on a thread that has long since gone quiet.
    ///
    /// Gating only the rendered value is not enough: `pulse` itself has to be reset
    /// under a finite animation to detach the repeating one from the view graph.
    private func syncPulse() {
        guard shouldPulse else {
            stopPulse()
            return
        }
        guard !pulse else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    private func stopPulse() {
        guard pulse else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            pulse = false
        }
    }

    private var shouldPulse: Bool {
        switch status {
        case .streaming, .awaitingPermission: return true
        default: return false
        }
    }
}

// MARK: - ProjectChatRow

struct ProjectChatRow: View {
    /// Leading disclosure control shown on a thread that has nested review
    /// children (the `[Code Review]` threads spawned from it).
    struct ReviewDisclosure {
        let count: Int
        let isExpanded: Bool
        /// True while at least one review child is still streaming — surfaces
        /// "this thread is being code-reviewed" on the parent row.
        let isReviewing: Bool
        let onToggle: () -> Void
    }

    let summary: ChatSession.Summary
    let isCurrent: Bool
    let status: ChatStatus
    let todoProgress: ChatTodoProgress?
    let linkedTask: ProjectTask?
    let isCreatingTask: Bool
    let onSelect: () -> Void
    let onOpenTask: () -> Void
    let onCreateTask: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void
    let onCodeReview: () -> Void
    let onCommitFiles: () -> Void
    /// Serializable action items (code review, commit, autopilot setup) supplied
    /// by hooks. Rendered via `MenuItemsView`; taps route through the desktop
    /// menu action handler.
    ///
    /// Deferred behind a closure so the hooks only run when the menu is actually
    /// opened. Building the array at the call site ran every enabled hook — some
    /// of which hit SwiftData — for every row on every view-graph update, to
    /// populate a menu nobody had opened yet.
    let hookMenuItems: () -> [MenuItem]
    /// Nesting depth; review children render one level in from their parent.
    var indentLevel: Int = 0
    /// Replaces the thread title (e.g. `"Review 1"` for a nested review child).
    var titleOverride: String? = nil
    /// Whether to show the `threadLabel` chip (hidden on review children since
    /// the nesting already conveys what they are).
    var showLabelChip: Bool = true
    var reviewDisclosure: ReviewDisclosure? = nil
    /// Latest code-review verdict for this thread: `true` passed, `false` found
    /// issues, `nil` not reviewed (no icon shown).
    var reviewPassed: Bool? = nil
    var hasFileChanges = false
    var pullRequest: ThreadPullRequest? = nil

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// Last loaded `+/−` totals, kept between hovers so the readout shows at once.
    @State private var changeTotals: ThreadChangeTotals?

    /// Width of the fade that blends a long title into the hover change stats.
    private static let changeStatsFadeWidth: CGFloat = 16

    private var showsChangeStats: Bool { isHovered && hasFileChanges && changeTotals != nil }

    /// `nil` unless the pointer is on a row with file changes, so idle rows never
    /// read — or re-render on — `threadFileEditsRevision`, which ticks on every edit.
    private var changeTotalsLoadID: Int? {
        guard isHovered, hasFileChanges else { return nil }
        return appState.threadFileEditsRevision
    }

    private var rowFill: Color {
        if isCurrent { return ClaudeTheme.accentSubtle }
        return isHovered ? ClaudeTheme.surfaceSecondary.opacity(0.45) : .clear
    }

    /// The row's fill over the sidebar background: what the row looks like on screen.
    private var rowSurface: some View {
        ClaudeTheme.sidebarBackground.overlay(rowFill)
    }

    /// True when this row *is* a `[Code Review]` thread (manual or hook-spawned).
    /// Such threads hide the "Code Review" / "Commit Files" actions since you
    /// don't review or commit a review thread itself.
    private var isCodeReviewThread: Bool {
        summary.threadLabel == AppState.manualCodeReviewLabel
    }

    /// The completion-check chip, driven by `AppState` rather than the label
    /// alone so a check whose verdict never landed stops claiming to verify.
    private var taskCompletionChip: (text: String, color: Color)? {
        switch appState.taskCompletionCheckState(for: summary) {
        case .verifying:
            return (String(localized: "Verifying"), ClaudeTheme.statusRunning)
        case .verified:
            return (String(localized: "Verified"), ClaudeTheme.statusSuccess)
        case .unverified:
            return (String(localized: "Unverified"), ClaudeTheme.statusWarning)
        case nil:
            return nil
        }
    }

    private var isActiveStatus: Bool {
        switch status {
        case .awaitingPermission, .done, .error: return true
        default: return false
        }
    }

    /// Title cleaned of `[Attached image: ...]` / `[ImageN]` / etc. markers that may
    /// be baked into older persisted summaries from before title stripping landed.
    ///
    /// Completion-check threads get a fixed title instead of their generated one —
    /// the row is only ever "the verification run for the parent thread", and the
    /// generated title just repeats the prompt.
    private var displayTitle: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        if taskCompletionChip != nil { return String(localized: "Task Verification") }
        let cleaned = ChatSession.stripAttachmentMarkers(from: summary.title)
        let resolved = cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
        return resolved.prefix(1).uppercased() + resolved.dropFirst()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let disclosure = reviewDisclosure {
                reviewDisclosureControl(disclosure)
            }

            if isActiveStatus {
                statusIndicator
            }

            if let pullRequest {
                pullRequestLink(pullRequest)
            }

            // The title takes every point the accessories don't use, so it only
            // truncates against what is actually on screen.
            HStack(spacing: 6) {
                Text(displayTitle)
                    .font(.system(size: ClaudeTheme.size(13), weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                titleDetails
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) { trailingDetails }
                .fixedSize()
                .padding(.leading, 2)
                .opacity(showsChangeStats ? 0 : 1)
                .accessibilityHidden(showsChangeStats)
        }
        // Drawn over the row instead of laid out in it: no width is reserved at
        // rest, and the title keeps its width and truncation while hovered.
        .overlay(alignment: .trailing) {
            if showsChangeStats, let changeTotals {
                changeStatsCover(changeTotals)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Fade in on hover; snap back on exit, together with the hover fill.
        .animation(reduceMotion || !showsChangeStats ? nil : .easeInOut(duration: 0.16), value: showsChangeStats)
        .padding(.leading, 18 + CGFloat(indentLevel) * 18)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(rowFill)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: changeTotalsLoadID) { await loadChangeTotals() }
        .help(taskCompletionChip.map { "\(displayTitle) — \($0.text)" } ?? displayTitle)
        .onTapGesture { onSelect() }
        .contextMenu { rowMenu }
    }

    /// The hover change stats on an opaque copy of the row's surface. They cover
    /// the trailing accessories, and the tail of a long title behind a short fade.
    private func changeStatsCover(_ totals: ThreadChangeTotals) -> some View {
        HStack(spacing: 0) {
            rowSurface
                .mask {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: Self.changeStatsFadeWidth)

            ProjectThreadChangesPreview(totals: totals)
                .padding(.leading, 2)
                .frame(maxHeight: .infinity)
                .background(rowSurface)
        }
    }

    /// Loads the thread's line totals while the pointer is on the row, and again
    /// whenever its file edits change during the hover.
    private func loadChangeTotals() async {
        guard isHovered, hasFileChanges else { return }
        let edits = await appState.loadThreadDiffPreview(sessionId: summary.id)
        guard !Task.isCancelled else { return }
        let stat = await ThreadDiffBanner.computeStat(edits)
        guard !Task.isCancelled else { return }
        let totals = ThreadChangeTotals(added: stat.added, removed: stat.removed)
        guard totals != changeTotals else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            changeTotals = totals
        }
    }

    @ViewBuilder
    private var titleDetails: some View {
        AttentionBadge(attention: appState.threadAttention(sessionKey: summary.id, in: windowState))

        if let taskCompletionChip {
            Text(taskCompletionChip.text)
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .foregroundStyle(taskCompletionChip.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(taskCompletionChip.color.opacity(0.14), in: Capsule())
                .fixedSize()
        }
    }

    @ViewBuilder
    private var trailingDetails: some View {
        if let linkedTask {
            Image(systemName: "link")
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .help("Linked task: \(linkedTask.title)")
                .accessibilityLabel("Linked task: \(linkedTask.title)")
        } else if isCreatingTask {
            ProgressView()
                .controlSize(.mini)
                .help("Creating task from chat")
        }

        if taskCompletionChip == nil, showLabelChip, let label = summary.threadLabel, !label.isEmpty {
            Text(label)
                .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(ClaudeTheme.accentSubtle, in: Capsule())
                .fixedSize()
        }

        if let reviewPassed {
            reviewVerdictIcon(passed: reviewPassed)
        }

        if hasFileChanges {
            Image(systemName: "plusminus.circle")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .accessibilityLabel("Thread has file changes")
        }

        if summary.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: ClaudeTheme.size(9)))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }

        if case .streaming = status {
            CompactSessionProgressView(progress: todoProgress)
        } else {
            Text(Self.compactElapsedTime(since: summary.updatedAt))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if linkedTask != nil {
            Button(action: onOpenTask) {
                Label("Jump to Task", systemImage: "link")
            }
        } else {
            Button(action: onCreateTask) {
                Label("Create Task from Chat with AI", systemImage: "sparkles")
            }
            .disabled(isCreatingTask)
        }
        Divider()
        Button { onRename() } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button { onTogglePin() } label: {
            if summary.isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin")
            }
        }
        Button { onToggleArchive() } label: {
            if summary.isArchived {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            } else {
                Label("Archive", systemImage: "archivebox")
            }
        }
        // Code review / commit / autopilot actions now come from hooks as
        // serializable MenuItems (gated for review threads and file changes
        // inside the hooks). The handler dispatches taps locally on desktop.
        let items = hookMenuItems()
        if !items.isEmpty {
            Divider()
            MenuItemsView(items)
                .menuActionHandler(appState.desktopMenuActionHandler(navigatingIn: windowState))
        }
        Divider()
        Button(role: .destructive) { onDelete() } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func pullRequestLink(_ pullRequest: ThreadPullRequest) -> some View {
        let isMerged = pullRequest.state == .merged
        let title = pullRequest.number.map { String(localized: "Pull request #\($0)") }
            ?? String(localized: "Pull request")
        let label: String
        switch pullRequest.state {
        case .merged: label = String(localized: "\(title) · Merged")
        case .closed: label = String(localized: "\(title) · Closed")
        case .open, nil: label = title
        }
        return Link(destination: pullRequest.url) {
            Image(systemName: isMerged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(isMerged ? Color.purple : ClaudeTheme.textSecondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint("Opens on GitHub")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .awaitingPermission, .done, .error:
            StatusBadgeDot(status: status)
        case .idle, .streaming:
            EmptyView()
        }
    }

    /// Code-review verdict badge: a green check when the latest review passed,
    /// a red exclamation when it found issues.
    @ViewBuilder
    private func reviewVerdictIcon(passed: Bool) -> some View {
        Image(systemName: passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
            .foregroundStyle(passed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
            .help(passed ? "Code review passed" : "Code review found issues")
            .accessibilityLabel(passed ? "Code review passed" : "Code review found issues")
    }

    /// Leading chevron that expands/collapses the nested review children, plus a
    /// review count / "reviewing" spinner.
    @ViewBuilder
    private func reviewDisclosureControl(_ disclosure: ReviewDisclosure) -> some View {
        Button(action: disclosure.onToggle) {
            HStack(spacing: 3) {
                Image(systemName: disclosure.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                    .frame(width: 10, height: 10)
                if disclosure.isReviewing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                } else {
                    Text("\(disclosure.count)")
                        .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(disclosure.isReviewing
            ? "Code review in progress"
            : (disclosure.isExpanded ? "Hide code reviews" : "Show \(disclosure.count) code review(s)"))
    }

    private static func compactElapsedTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "0m" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }

        return "\(days / 365)y"
    }
}

// MARK: - CompactSessionProgressView

private struct CompactSessionProgressView: View {
    let progress: ChatTodoProgress?

    private var fraction: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return min(1, max(0, Double(progress.done) / Double(progress.total)))
    }

    private var helpText: String {
        guard let progress, progress.total > 0 else { return String(localized: "Response in progress") }
        return String(format: String(localized: "Todos %lld/%lld"), progress.done, progress.total)
    }

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: fraction, total: 1)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.circular)
        .controlSize(.small)
        .frame(width: 14, height: 14)
        .help(helpText)
        .accessibilityLabel(helpText)
        .animation(.easeInOut(duration: 0.2), value: fraction)
    }
}
