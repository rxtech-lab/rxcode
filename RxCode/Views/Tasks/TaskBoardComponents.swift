import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Sheet payload

/// What the board's sheet is editing. `ProjectTask` and `ProjectStory` are both
/// `Identifiable`, but `.sheet(item:)` needs one type, so they're unified here.
enum TaskBoardSheet: Identifiable {
    case task(ProjectTask)
    case story(ProjectStory)

    var id: String {
        switch self {
        case .task(let task): return "task-\(task.id.uuidString)"
        case .story(let story): return "story-\(story.id.uuidString)"
        }
    }
}

// MARK: - Column styling

extension TaskColumn {
    var tint: Color { Color(hex: colorHex) }

    /// The one-line description under a board column header: the column's own
    /// description, or a summary of what it automates.
    var columnDescription: String {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? triggerSummary : trimmed
    }

    /// "Starts a chat · On session stop → Pending Review" style summary.
    var triggerSummary: String {
        triggerSummary(columnName: { $0.rawValue })
    }

    func triggerSummary(columnName: (TaskStatus) -> String) -> String {
        var parts: [String] = []
        if triggersChat { parts.append(String(localized: "Starts a chat")) }
        for event in TaskTriggerEvent.allCases {
            if let target = target(for: event) {
                parts.append("\(String(localized: event.displayName)) → \(columnName(target))")
            }
        }
        if countsAsDone { parts.append(String(localized: "Counts as done")) }
        return parts.joined(separator: " · ")
    }
}

extension TaskBoard {
    /// A column's trigger summary with target ids resolved to column names.
    func triggerSummary(for column: TaskColumn) -> String {
        column.triggerSummary { self.column(for: $0).name }
    }
}

/// The ring glyph of a column, in its color.
struct TaskStatusIcon: View {
    let column: TaskColumn
    var size: CGFloat = 12

    init(column: TaskColumn, size: CGFloat = 12) {
        self.column = column
        self.size = size
    }

    init(status: TaskStatus, board: TaskBoard, size: CGFloat = 12) {
        self.init(column: board.column(for: status), size: size)
    }

    var body: some View {
        Image(systemName: column.systemImage)
            .font(.system(size: ClaudeTheme.size(size), weight: .semibold))
            .foregroundStyle(column.tint)
            .help(Text(column.name))
    }
}

/// The rounded count bubble beside a column or section title.
struct TaskCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            .foregroundStyle(ClaudeTheme.textSecondary)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(ClaudeTheme.surfaceTertiary))
    }
}

/// Outlined label pill (version, tag, story) matching GitHub's field chips.
struct TaskPill: View {
    let text: String
    var icon: String?
    var tint: Color = ClaudeTheme.textSecondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
            }
            Text(text)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Motion

/// Shared timing for the task pages, so cards, columns, tabs and project cards
/// all move with the same feel.
enum TaskBoardMotion {
    /// Cards changing column or order, columns and tabs being reordered.
    static let move = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Drop-target highlights and hover lifts: quick, so they track the pointer.
    static let feedback = Animation.easeOut(duration: 0.16)

    /// A card arriving in or leaving a column or list.
    static let card: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.94).combined(with: .opacity),
        removal: .scale(scale: 0.97).combined(with: .opacity)
    )
}

extension View {
    /// `.animation(_:value:)` that turns itself off under Reduce Motion.
    func taskBoardAnimation<V: Equatable>(_ animation: Animation = TaskBoardMotion.move, value: V) -> some View {
        modifier(TaskBoardAnimation(animation: animation, value: value))
    }

    /// The accent outline and slight lift a drop target shows while something
    /// is dragged over it. Mirrors the composer's drag affordance
    /// (`InputBarView.dragOverlay`).
    func taskDropHighlight(_ isTargeted: Bool, in shape: some InsettableShape, scale: CGFloat = 1.01) -> some View {
        modifier(TaskDropHighlight(isTargeted: isTargeted, shape: shape, scale: scale))
    }
}

private struct TaskBoardAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct TaskDropHighlight<S: InsettableShape>: ViewModifier {
    let isTargeted: Bool
    let shape: S
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    shape
                        .strokeBorder(ClaudeTheme.accent.opacity(0.6), lineWidth: 2, antialiased: true)
                        .background(ClaudeTheme.accent.opacity(0.05), in: shape)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isTargeted && !reduceMotion ? scale : 1)
            .animation(reduceMotion ? nil : TaskBoardMotion.feedback, value: isTargeted)
    }
}

// MARK: - Classification styling

extension TaskPriority {
    var tint: Color { Color(hex: colorHex) }
}

extension TaskItemType {
    var tint: Color { Color(hex: colorHex) }
}

extension TaskBoard {
    /// A tag's label color, or the neutral pill color when it has none.
    func tint(forTag tag: String) -> Color {
        labelColorHex(for: tag).map { Color(hex: $0) } ?? ClaudeTheme.textSecondary
    }
}

/// Small filled dot used beside type and label names in pickers and lists.
struct TaskColorDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// The classification fields shared by stories and tasks, as pills: type,
/// priority, milestone, version, then tags — each in its board color.
struct TaskClassificationPills: View {
    let board: TaskBoard
    var typeId: UUID?
    var priority: TaskPriority?
    var version: String?
    var milestone: String?
    var tags: [String] = []

    var hasContent: Bool {
        board.itemType(id: typeId) != nil || priority != nil || !(version ?? "").isEmpty
            || !(milestone ?? "").isEmpty || !tags.isEmpty
    }

    var body: some View {
        if let type = board.itemType(id: typeId) {
            TaskPill(text: type.name, icon: "circle.fill", tint: type.tint)
        }
        if let priority {
            TaskPill(text: priority.displayNameText, icon: priority.systemImage, tint: priority.tint)
        }
        if let milestone, !milestone.isEmpty {
            TaskPill(text: milestone, icon: "flag", tint: ClaudeTheme.statusSuccess)
        }
        if let version, !version.isEmpty {
            TaskPill(text: version, icon: "tag", tint: ClaudeTheme.accent)
        }
        ForEach(tags, id: \.self) { tag in
            TaskPill(text: tag, tint: board.tint(forTag: tag))
        }
    }
}

extension TaskClassificationPills {
    init(task: ProjectTask, board: TaskBoard) {
        self.init(
            board: board,
            typeId: task.typeId,
            priority: task.priority,
            version: task.version,
            milestone: task.milestone,
            tags: task.tags
        )
    }

    init(story: ProjectStory, board: TaskBoard) {
        self.init(
            board: board,
            typeId: story.typeId,
            priority: story.priority,
            version: story.version,
            milestone: story.milestone,
            tags: story.tags
        )
    }
}

/// A selected value in a form — a tag, version or milestone — as a tinted
/// chip that removes the value when clicked.
struct TaskRemovableChip: View {
    let text: String
    var icon: String?
    var tint: Color = ClaudeTheme.textSecondary
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
                }
                Text(text)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
            }
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

/// A single-value field that works like the tags field: a combobox to search
/// the board's existing values or type a new one (Return), with the current
/// value shown as a removable chip. Picking another value replaces it.
struct TaskSingleValueCombo: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    let icon: String
    let tint: Color
    @Binding var value: String?
    /// The combobox text, owned by the form so Save can commit a value that
    /// was typed but not confirmed with Return.
    @Binding var input: String
    let options: [String]
    var manageTitle: LocalizedStringKey = "Manage…"
    var onManage: (() -> Void)?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let value, !value.isEmpty {
                    TaskRemovableChip(text: value, icon: icon, tint: tint) {
                        self.value = nil
                    }
                    .fixedSize()
                }
                TaskComboField(
                    title: title,
                    prompt: prompt,
                    text: $input,
                    options: options.filter { $0 != value }.map { TaskComboOption(name: $0, color: tint) },
                    onSubmit: commit,
                    onPick: { picked in
                        input = picked
                        commit()
                    },
                    showsLabel: false,
                    manageTitle: manageTitle,
                    onManage: onManage
                )
            }
        }
    }

    private func commit() {
        if let committed = Self.resolve(input, in: options) {
            value = committed
        }
        input = ""
    }

    /// The value `text` names, reusing an existing value's spelling when it
    /// differs only by case. `nil` for blank text.
    static func resolve(_ text: String, in options: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return options.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }
}

/// One choice offered by a `TaskComboField`.
struct TaskComboOption: Hashable {
    let name: String
    var color: Color?
}

/// A combobox: a text field whose dropdown lists the board's existing values
/// filtered by what's typed, plus a chevron that browses all of them. Picking
/// reuses a value; typing a new one and pressing Return creates it. This is
/// how types, tags, versions and milestones are shared between stories and
/// tasks without retyping them.
struct TaskComboField: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String
    let options: [TaskComboOption]
    /// Return pressed. `nil` for fields where the typed text is the value.
    var onSubmit: (() -> Void)?
    /// An option chosen from the chevron menu.
    let onPick: (String) -> Void
    var showsLabel = true
    /// Adds a "Manage…" item to the dropdown, e.g. to open the fields sheet.
    var manageTitle: LocalizedStringKey = "Manage…"
    var onManage: (() -> Void)?

    /// Options containing the typed text, exact prefix matches first.
    private var matches: [TaskComboOption] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return options }
        let lowered = needle.lowercased()
        let found = options.filter { $0.name.localizedCaseInsensitiveContains(needle) && $0.name != needle }
        return found.filter { $0.name.lowercased().hasPrefix(lowered) }
            + found.filter { !$0.name.lowercased().hasPrefix(lowered) }
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden(!showsLabel)
                .multilineTextAlignment(.leading)
                .onSubmit { onSubmit?() }
                .textInputSuggestions {
                    ForEach(matches, id: \.self) { option in
                        optionLabel(option)
                            .textInputCompletion(option.name)
                    }
                }

            if !options.isEmpty || onManage != nil {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onPick(option.name)
                        } label: {
                            optionLabel(option)
                        }
                    }
                    if !text.isEmpty, onSubmit == nil {
                        Divider()
                        Button("Clear") { onPick("") }
                    }
                    if let onManage {
                        if !options.isEmpty { Divider() }
                        Button(manageTitle, action: onManage)
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose an existing value")
            }
        }
    }

    @ViewBuilder
    private func optionLabel(_ option: TaskComboOption) -> some View {
        if let color = option.color {
            Label {
                Text(option.name)
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(color)
            }
        } else {
            Text(option.name)
        }
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// "5 / 6  ▰▰▰▨▱  83%" — rolled-up story progress. Finished children fill the
/// bar solid; started-but-unfinished children follow as an animated striped
/// "pending" segment in `activeTint`, with a live "N in progress" caption.
struct StoryProgressBar: View {
    let progress: StoryProgress
    var tint: Color = ClaudeTheme.accent
    var activeTint: Color = ClaudeTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(progress.done) / \(progress.total)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .monospacedDigit()

                StoryProgressTrack(progress: progress, tint: tint, activeTint: activeTint)
                    .frame(height: 6)

                Text("\(progress.percent)%")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .monospacedDigit()
            }

            if progress.active > 0 {
                HStack(spacing: 5) {
                    PulsingDot(color: activeTint)
                    Text("\(progress.active) in progress")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(activeTint)
                        .monospacedDigit()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(progress.done) of \(progress.total) tasks done, \(progress.active) in progress"))
    }
}

extension StoryProgressBar {
    /// Colors the bar with the board's own columns: the first done column for
    /// finished work and the first chat column for the pending segment.
    init(story: ProjectStory, board: TaskBoard) {
        self.init(
            progress: board.progress(for: story),
            tint: board.effectiveColumns.first(where: \.countsAsDone)?.tint ?? ClaudeTheme.accent,
            activeTint: board.firstChatColumn?.tint ?? ClaudeTheme.accent
        )
    }
}

/// The bar itself: solid done segment, striped pending segment, then track.
private struct StoryProgressTrack: View {
    let progress: StoryProgress
    let tint: Color
    let activeTint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let doneWidth = width * progress.fraction
            let activeWidth = width * progress.activeFraction
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))

                if activeWidth > 0 {
                    PendingStripes(color: activeTint)
                        .frame(width: doneWidth + activeWidth)
                        .clipShape(Capsule())
                }

                if doneWidth > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: doneWidth)
                }
            }
        }
    }
}

/// Diagonal barber-pole stripes that drift left to right while work is
/// underway. The motion is a single repeating offset animation, so it stays
/// cheap on boards with many stories; Reduce Motion freezes it.
private struct PendingStripes: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    private let period: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.35)))
                var stripes = Path()
                var x = -height - period
                while x < size.width + period {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + height, y: 0))
                    stripes.addLine(to: CGPoint(x: x + height + period / 2, y: 0))
                    stripes.addLine(to: CGPoint(x: x + period / 2, y: size.height))
                    stripes.closeSubpath()
                    x += period
                }
                context.fill(stripes, with: .color(color.opacity(0.85)))
            }
            .frame(width: proxy.size.width + period * 2)
            .offset(x: phase - period * 2)
        }
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                phase = period
            }
        }
    }
}

/// Small status dot with a soft expanding halo.
private struct PulsingDot: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background(
                Circle()
                    .fill(color.opacity(isPulsing ? 0 : 0.5))
                    .scaleEffect(isPulsing ? 2.4 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
    }
}

/// GitHub's "Filter by keyword" bar.
struct TaskFilterField: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "Filter by keyword"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: ClaudeTheme.size(13)))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.inputBorder, lineWidth: 1)
        )
    }
}

/// Header filter chip. Mirrors the composer/toolbar chip styling in
/// `ChatToolbarComponents` so the board header reads as part of the same app.
struct TaskBoardChipLabel: View {
    let icon: String
    let title: String
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            Text(title)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
        }
        .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(isActive ? ClaudeTheme.accent.opacity(0.10) : ClaudeTheme.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Shared menus

/// Right-click actions for a task, shared by board cards, table rows and the
/// overview list so every surface offers the same verbs.
struct TaskContextMenuItems: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let task: ProjectTask
    let onEdit: () -> Void
    /// Called before revealing the chat, so a sheet hosting this menu can
    /// dismiss itself instead of staying over the thread.
    var onOpenChat: (() -> Void)?

    private var board: TaskBoard { appState.taskBoard(for: task.projectId) }

    var body: some View {
        Button("Edit…", action: onEdit)

        if appState.canOpenChat(for: task) {
            Button("Open Chat") {
                onOpenChat?()
                appState.openChat(for: task, in: windowState)
            }
        }

        if task.agent.isAssigned, !board.column(for: task.status).triggersChat,
           let chatColumn = board.firstChatColumn {
            Button("Run with Agent") {
                appState.moveTask(task, to: chatColumn.id)
            }
        }

        Divider()

        Menu("Move To") {
            ForEach(board.effectiveColumns) { column in
                Button(column.name) {
                    appState.moveTask(task, to: column.id)
                }
                .disabled(column.id == board.resolvedStatus(of: task))
            }
        }
        .disabled(board.isStatusLocked(task))

        Divider()

        Button("Delete", role: .destructive) {
            appState.deleteTask(task)
        }
    }
}

struct StoryContextMenuItems: View {
    @Environment(AppState.self) private var appState

    let story: ProjectStory
    let onEdit: () -> Void
    /// Opens the task form on a draft already parented to this story.
    let onNewTask: (ProjectTask) -> Void

    var body: some View {
        Button("New Task") {
            onNewTask(appState.newTaskDraft(inStory: story))
        }
        Button("Edit…", action: onEdit)
        Divider()
        Button("Delete", role: .destructive) {
            appState.deleteStory(story)
        }
    }
}

// MARK: - Agent label

extension AppState {
    /// "Opus · high" style summary of a task's agent assignment.
    func taskAgentLabel(_ agent: TaskAgentConfig) -> String {
        var parts: [String] = []
        if let model = agent.model, !model.isEmpty {
            parts.append(modelDisplayLabel(model, provider: agent.provider ?? .claudeCode))
        } else if let provider = agent.provider {
            parts.append(provider.displayNameText)
        }
        if let effort = agent.effort, !effort.isEmpty {
            parts.append(effort)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Story identity

extension ProjectStory {
    /// A stable per-story color, so a story and its tasks read as one group
    /// across board columns. Derived from the id rather than stored, so it
    /// needs no persistence and stays the same across launches.
    var tint: Color {
        let palette: [Color] = [
            ClaudeTheme.accent, ClaudeTheme.statusRunning, .purple, ClaudeTheme.statusSuccess,
            .pink, .teal, .indigo, ClaudeTheme.statusWarning,
        ]
        let seed = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return palette[seed % palette.count]
    }
}

/// The story a task belongs to, as a tinted chip on the task card. Tapping
/// shows a popover with the story's name and progress; hovering highlights the
/// story and its sibling tasks on the board.
struct TaskStoryChip: View {
    let story: ProjectStory
    let progress: StoryProgress
    let column: TaskColumn
    @Binding var hoveredStoryId: UUID?

    @State private var showsPopover = false

    var body: some View {
        // A button, not a tap gesture, so the tap wins over the card's own
        // tap-to-edit gesture.
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(story.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(story.tint.opacity(showsPopover ? 0.26 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show story")
        .onHover { hovering in
            if hovering {
                hoveredStoryId = story.id
            } else if hoveredStoryId == story.id {
                hoveredStoryId = nil
            }
        }
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(story.tint)
                    Text("Story")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Spacer(minLength: 0)
                    TaskStatusIcon(column: column, size: 11)
                }
                Text(story.title.isEmpty ? String(localized: "Untitled story") : story.title)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                StoryProgressBar(progress: progress)
            }
            .padding(12)
            .frame(width: 240)
        }
    }
}

// MARK: - Task summary

/// Two-line preview of what a task is about, with an icon that opens the full
/// text in a popover. Prefers the generated summary of the thread the agent
/// ran in (what was actually done); falls back to the task's description.
struct TaskSummaryPreview: View {
    @Environment(AppState.self) private var appState

    let task: ProjectTask

    @State private var showsFull = false

    private var content: (title: LocalizedStringKey, text: String)? {
        if let key = task.sessionKey {
            // Re-read when a thread summary is regenerated.
            _ = appState.threadSummaryRevision
            let sessionId = appState.resolveCurrentSessionId(key)
            let summary = appState.threadStore.threadSummaryItem(sessionId: sessionId)?.summary
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty { return ("Agent Summary", summary) }
        }
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? nil : ("Description", details)
    }

    var body: some View {
        if let content {
            HStack(alignment: .top, spacing: 6) {
                // Stripped, not rendered: descriptions are Markdown, and two
                // truncated lines of a card have no room for block layout —
                // raw syntax would just eat the preview.
                Text(stripMarkdown(content.text))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showsFull.toggle()
                } label: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                        .foregroundStyle(showsFull ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(content.title))
                .popover(isPresented: $showsFull, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(content.title)
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        ScrollView {
                            MarkdownContentView(text: content.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 360)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 340)
                }
            }
        }
    }
}
