import AppIntents
import RxCodeCore
import SwiftUI
import WidgetKit

struct DesktopWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: DesktopWidgetSnapshot
    var projectID: UUID?
    var agentID: String?
}

struct DesktopWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DesktopWidgetEntry { .preview }
    func getSnapshot(in context: Context, completion: @escaping (DesktopWidgetEntry) -> Void) {
        completion(DesktopWidgetEntry(date: .now, snapshot: DesktopWidgetEntry.snapshot(isPreview: context.isPreview)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DesktopWidgetEntry>) -> Void) {
        completion(Timeline(entries: [DesktopWidgetEntry(date: .now, snapshot: DesktopWidgetStore.load())], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct ProjectWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DesktopWidgetEntry { .preview }
    func snapshot(for configuration: ProjectWidgetIntent, in context: Context) async -> DesktopWidgetEntry {
        DesktopWidgetEntry(date: .now, snapshot: DesktopWidgetEntry.snapshot(isPreview: context.isPreview), projectID: configuration.project?.id == WidgetProjectEntity.all.id ? nil : configuration.project?.id)
    }
    func timeline(for configuration: ProjectWidgetIntent, in context: Context) async -> Timeline<DesktopWidgetEntry> {
        Timeline(entries: [await snapshot(for: configuration, in: context)], policy: .after(.now.addingTimeInterval(900)))
    }
}

struct AgentWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DesktopWidgetEntry { .preview }
    func snapshot(for configuration: AgentWidgetIntent, in context: Context) async -> DesktopWidgetEntry {
        DesktopWidgetEntry(date: .now, snapshot: DesktopWidgetEntry.snapshot(isPreview: context.isPreview), agentID: configuration.agent?.id == WidgetAgentEntity.all.id ? nil : configuration.agent?.id)
    }
    func timeline(for configuration: AgentWidgetIntent, in context: Context) async -> Timeline<DesktopWidgetEntry> {
        Timeline(entries: [await snapshot(for: configuration, in: context)], policy: .after(.now.addingTimeInterval(900)))
    }
}

private let widgetAccent = Color(red: 0.85, green: 0.47, blue: 0.34)

private var activityWidgetFamilies: [WidgetFamily] {
    var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    if #available(macOS 27.0, *) { families.append(.systemExtraLargePortrait) }
    return families
}

struct TaskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DesktopWidgetEntry
    var ongoingOnly = false

    private var isPortrait: Bool {
        if #available(macOS 27.0, *) { return family == .systemExtraLargePortrait }
        return false
    }
    private var isWide: Bool { family == .systemMedium || family == .systemExtraLarge }
    private var projects: [WidgetProject] {
        entry.snapshot.projects.filter { entry.projectID == nil || $0.id == entry.projectID }
    }
    private var threads: [WidgetThread] {
        entry.snapshot.threadRows(projectID: entry.projectID, limit: limit, now: entry.date)
    }
    private var rows: [(project: WidgetProject, task: WidgetTask)] {
        entry.snapshot.taskRows(projectID: entry.projectID, ongoingOnly: ongoingOnly,
            limit: family == .systemSmall && !threads.isEmpty ? 1 : limit, now: entry.date)
    }
    private var limit: Int {
        if isPortrait { return 6 }
        if family == .systemExtraLarge { return 5 }
        if family == .systemLarge { return ongoingOnly ? 3 : 2 }
        return 2
    }

    private var destination: URL {
        if family == .systemSmall {
            if let thread = threads.first(where: \.isOngoing) {
                return entry.snapshot.url(projectID: thread.projectID, threadID: thread.id)
            }
            if let row = rows.first {
                return entry.snapshot.url(projectID: row.project.id, taskID: row.task.id)
            }
            if let thread = threads.first {
                return entry.snapshot.url(projectID: thread.projectID, threadID: thread.id)
            }
        }
        return entry.snapshot.url(projectID: entry.projectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ongoingOnly ? "Ongoing Activity" : "Project Activity", systemImage: "checklist")
                .font(.caption.weight(.semibold))
            Text(entry.projectID == nil ? entry.snapshot.workspaceName : (projects.first?.name ?? "Project unavailable"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if rows.isEmpty && threads.isEmpty {
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if isWide {
                HStack(alignment: .top, spacing: 12) {
                    taskSection
                    Divider()
                    threadSection
                }.frame(maxHeight: .infinity, alignment: .top)
            } else {
                if !rows.isEmpty { taskSection }
                if !threads.isEmpty {
                    if family != .systemSmall { Divider() }
                    threadSection
                }
                Spacer(minLength: 0)
            }
            if !ongoingOnly, family != .systemSmall, family != .systemMedium,
               let project = projects.first,
               let story = (project.stories.first(where: { $0.taskCount == 0 || $0.doneCount < $0.taskCount }) ?? project.stories.first) {
                Divider()
                Link(destination: entry.snapshot.url(projectID: project.id)) {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text(story.title).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(story.doneCount)/\(story.taskCount)").monospacedDigit()
                    }.font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            WidgetUpdatedLabel(date: entry.snapshot.updatedAt)
        }
        .widgetURL(destination)
        .containerBackground(.fill.tertiary, for: .widget)
        .privacySensitive()
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if family != .systemSmall { Text("Tasks").font(.caption2.bold()).foregroundStyle(.secondary) }
            ForEach(rows, id: \.task.id) { row in
                Link(destination: entry.snapshot.url(projectID: row.project.id, taskID: row.task.id)) {
                    activityRow(title: row.task.title, detail: "\(row.project.name) · \(row.task.isDone ? "Recently finished" : (row.task.isQueued ? "Queued" : row.task.status))",
                        icon: row.task.isDone ? "checkmark.circle.fill" : (row.task.isOngoing ? "bolt.fill" : "circle"),
                        color: row.task.isDone ? .green : widgetAccent)
                }.buttonStyle(.plain)
            }
            if rows.isEmpty {
                Text("No recent task activity").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if family != .systemSmall { Text("Chat threads").font(.caption2.bold()).foregroundStyle(.secondary) }
            ForEach(threads) { thread in
                Link(destination: entry.snapshot.url(projectID: thread.projectID, threadID: thread.id)) {
                    activityRow(title: thread.title,
                        detail: "\(thread.projectName) · \(thread.isOngoing ? "Ongoing" : "Recently stopped")",
                        icon: thread.isOngoing ? "bubble.left.and.text.bubble.right.fill" : "stop.circle",
                        color: thread.isOngoing ? widgetAccent : .secondary)
                }.buttonStyle(.plain)
            }
            if threads.isEmpty {
                Text("No recent chat activity").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityRow(title: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).lineLimit(1)
            }.font(.caption.weight(.medium))
            if family != .systemSmall {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var emptyMessage: String {
        if entry.snapshot.updatedAt == .distantPast { return "Open RxCode to load your projects." }
        if entry.projectID != nil && projects.isEmpty { return "Choose a project from the current workspace in Edit Widget." }
        return "No ongoing or recent activity."
    }
}

struct AgentUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DesktopWidgetEntry
    private var matchingAgents: [WidgetAgentUsage] {
        entry.snapshot.agents.filter { entry.agentID == nil || $0.id == entry.agentID }
    }
    private var agents: [WidgetAgentUsage] { Array(matchingAgents.prefix(family == .systemLarge ? 4 : 2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 8) {
            Label("Agent Usage", systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption.weight(.semibold))
            if agents.isEmpty {
                Text(entry.agentID == nil ? "Open RxCode to load agent limits." : "Agent unavailable. Choose an agent in Edit Widget.").font(.caption).foregroundStyle(.secondary)
            }
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(agents) { agent in
                        agentSection(agent).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ForEach(agents) { agent in agentSection(agent) }
            }
            if matchingAgents.count > agents.count, family != .systemSmall {
                Text("+\(matchingAgents.count - agents.count) more · Select an agent in Edit Widget")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            WidgetUpdatedLabel(date: entry.snapshot.updatedAt)
        }
        .widgetURL(entry.snapshot.url(usage: true))
        .containerBackground(.fill.tertiary, for: .widget)
        .privacySensitive()
    }

    private func agentSection(_ agent: WidgetAgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agent.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let measuredAt = agent.measuredAt, family == .systemLarge {
                    Text(measuredAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let usage = agent.usage {
                if usage.hasFiveHourLimit { usageRow("5h", percent: usage.fiveHourPercent, reset: usage.fiveHourResetsAt) }
                if let daily = usage.twentyFourHourPercent { usageRow("24h", percent: daily, reset: usage.twentyFourHourResetsAt) }
                usageRow("7d", percent: usage.sevenDayPercent, reset: usage.sevenDayResetsAt)
            } else {
                Text(agent.supportsLimits ? "Usage unavailable" : "Limits not reported by this client")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func usageRow(_ label: String, percent: Double, reset: Date?) -> some View {
        let safe = percent.isFinite ? min(100, max(0, percent)) : 0
        let expired = reset.map { $0 <= entry.date } ?? false
        return HStack(spacing: 5) {
            Text(label).frame(width: 20, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(safe >= 90 ? Color.red : widgetAccent)
                        .frame(width: geometry.size.width * (expired ? 0 : safe / 100))
                }
            }.frame(height: 4)
            Text(expired ? "—" : "\(Int(safe.rounded()))%")
                .monospacedDigit().frame(width: 32, alignment: .trailing)
            if family == .systemLarge, let reset {
                if expired { Text("Awaiting refresh") }
                else { Text(reset, style: .relative) }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage: \(expired ? "awaiting refresh" : "\(Int(safe)) percent used")")
    }
}

private struct WidgetUpdatedLabel: View {
    let date: Date
    var body: some View {
        if date == .distantPast { Text("No data yet").font(.caption2).foregroundStyle(.tertiary) }
        else {
            HStack(spacing: 3) {
                Text("Updated")
                Text(date, style: .relative)
            }.font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct ProjectTasksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "RxCodeProjectTasks", intent: ProjectWidgetIntent.self, provider: ProjectWidgetProvider()) { entry in
            TaskWidgetView(entry: entry)
        }
        .configurationDisplayName("Project Tasks")
        .description("Tasks and chat threads, including recently finished or stopped activity. Choose a project with Edit Widget.")
        .supportedFamilies(activityWidgetFamilies)
    }
}
struct OngoingTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RxCodeOngoingTasks", provider: DesktopWidgetProvider()) { entry in
            TaskWidgetView(entry: entry, ongoingOnly: true)
        }
        .configurationDisplayName("Ongoing Tasks")
        .description("Ongoing tasks and chat threads, plus finished and stopped activity from the last seven days.")
        .supportedFamilies(activityWidgetFamilies)
    }
}
struct AgentUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "RxCodeAgentUsage", intent: AgentWidgetIntent.self, provider: AgentWidgetProvider()) { entry in
            AgentUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Agent Usage")
        .description("Claude Code and Codex usage limits, reset times, and ACP availability.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct DesktopWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProjectTasksWidget()
        OngoingTasksWidget()
        AgentUsageWidget()
        IntegrationUsageWidget()
    }
}

extension DesktopWidgetEntry {
    static func snapshot(isPreview: Bool) -> DesktopWidgetSnapshot {
        let saved = DesktopWidgetStore.load()
        return isPreview && saved.updatedAt == .distantPast ? preview.snapshot : saved
    }

    static var preview: Self {
        let projectID = UUID()
        let story = ProjectStory(projectId: projectID, title: "Desktop widgets")
        let board = TaskBoard(stories: [story], tasks: [
            ProjectTask(projectId: projectID, storyId: story.id, title: "Build project overview", status: .inProgress, sessionKey: "preview"),
            ProjectTask(projectId: projectID, storyId: story.id, title: "Review usage limits", status: .done)
        ])
        return Self(date: .now, snapshot: DesktopWidgetSnapshot(workspaceID: "personal", workspaceName: "Personal",
            projects: [WidgetProject(id: projectID, name: "RxCode", board: board)], agents: [
                WidgetAgentUsage(id: "claude", name: "Claude Code", usage: RateLimitUsage(fiveHourPercent: 45, sevenDayPercent: 18, fiveHourResetsAt: .now.addingTimeInterval(3600), sevenDayResetsAt: .now.addingTimeInterval(86400))),
                WidgetAgentUsage(id: "codex", name: "Codex", usage: nil),
                WidgetAgentUsage(id: "acp", name: "ACP Client", usage: nil, supportsLimits: false)
            ], threads: [
                WidgetThread(id: "preview-chat", projectID: projectID, projectName: "RxCode", title: "Review widget layout", isOngoing: true, updatedAt: .now),
                WidgetThread(id: "preview-stopped", projectID: projectID, projectName: "RxCode", title: "Investigate build", isOngoing: false, updatedAt: .now.addingTimeInterval(-600))
            ]))
    }
}

#Preview(as: .systemMedium) { ProjectTasksWidget() } timeline: { DesktopWidgetEntry.preview }
#Preview(as: .systemLarge) { AgentUsageWidget() } timeline: { DesktopWidgetEntry.preview }

#Preview(as: .systemSmall) { ProjectTasksWidget() } timeline: { DesktopWidgetEntry.preview }
#Preview(as: .systemLarge) { OngoingTasksWidget() } timeline: { DesktopWidgetEntry.preview }

#Preview(as: .systemExtraLarge) { ProjectTasksWidget() } timeline: { DesktopWidgetEntry.preview }
@available(macOS 27.0, *)
#Preview(as: .systemExtraLargePortrait) { ProjectTasksWidget() } timeline: { DesktopWidgetEntry.preview }

struct IntegrationUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RxCodeIntegrationUsage", provider: DesktopWidgetProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Text("Usage integrations").font(.headline)
                let dashboard = entry.snapshot.usageDashboard ?? UsageDashboard()
                let cards = dashboard.cards.filter(\.showInWidget)
                if cards.isEmpty { Text("Select cards in Briefing → Manage cards").foregroundStyle(.secondary) }
                ForEach(Array(cards.prefix(3))) { card in
                    if let snapshot = dashboard.snapshot(for: card) {
                        VStack(alignment: .leading) {
                            Text(snapshot.title).font(.caption.bold())
                            if let metric = snapshot.metrics.first(where: { card.includesMetric($0.id) }) {
                                Text("\(metric.title): \(metric.formattedValue)").font(.caption)
                            }
                            Text(snapshot.isStale(at: entry.date) ? "Stale" : snapshot.period).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.snapshot.url(usage: true))
        }
        .configurationDisplayName("Usage integrations")
        .description("Pinned billing, cloud consumption, AI usage, and CI wait times.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
