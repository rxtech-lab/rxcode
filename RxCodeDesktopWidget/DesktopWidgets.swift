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

struct TaskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DesktopWidgetEntry
    var ongoingOnly = false

    private var projects: [WidgetProject] {
        entry.snapshot.projects.filter { entry.projectID == nil || $0.id == entry.projectID }
    }
    private var rows: [(project: WidgetProject, task: WidgetTask)] {
        projects.flatMap { project in
            project.tasks.filter { ongoingOnly ? $0.isOngoing : !$0.isDone }.map { (project, $0) }
        }.sorted {
            if $0.task.isOngoing != $1.task.isOngoing { return $0.task.isOngoing }
            return false
        }
    }
    private var limit: Int { family == .systemLarge ? 5 : (family == .systemMedium && ongoingOnly ? 2 : 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(ongoingOnly ? "Ongoing Tasks" : "Project Tasks", systemImage: ongoingOnly ? "bolt.fill" : "checklist")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(rows.count)").font(.title3.bold()).monospacedDigit().foregroundStyle(widgetAccent)
            }
            Text(entry.projectID == nil ? entry.snapshot.workspaceName : (projects.first?.name ?? "Project unavailable"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if rows.isEmpty {
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ForEach(Array(rows.prefix(limit)), id: \.task.id) { row in
                    Link(destination: entry.snapshot.url(projectID: row.project.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: row.task.isOngoing ? "bolt.fill" : "circle")
                                    .foregroundStyle(widgetAccent)
                                Text(row.task.title).lineLimit(1)
                            }.font(.caption.weight(.medium))
                            Text("\(row.project.name) · \(row.task.isQueued ? "Queued" : row.task.status)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            if !ongoingOnly, family != .systemSmall,
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
        .widgetURL(entry.snapshot.url(projectID: entry.projectID))
        .containerBackground(.fill.tertiary, for: .widget)
        .privacySensitive()
    }

    private var emptyMessage: String {
        if entry.snapshot.updatedAt == .distantPast { return "Open RxCode to load your projects." }
        if entry.projectID != nil && projects.isEmpty { return "Choose a project from the current workspace in Edit Widget." }
        return ongoingOnly ? "No ongoing tasks." : "No open tasks. Open RxCode to view your board."
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
        .description("Open tasks and story progress. Choose a project with Edit Widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct OngoingTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RxCodeOngoingTasks", provider: DesktopWidgetProvider()) { entry in
            TaskWidgetView(entry: entry, ongoingOnly: true)
        }
        .configurationDisplayName("Ongoing Tasks")
        .description("Tasks currently owned by agents across the active workspace.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
            ProjectTask(projectId: projectID, storyId: story.id, title: "Review usage limits", status: .pending)
        ])
        return Self(date: .now, snapshot: DesktopWidgetSnapshot(workspaceID: "personal", workspaceName: "Personal",
            projects: [WidgetProject(id: projectID, name: "RxCode", board: board)], agents: [
                WidgetAgentUsage(id: "claude", name: "Claude Code", usage: RateLimitUsage(fiveHourPercent: 45, sevenDayPercent: 18, fiveHourResetsAt: .now.addingTimeInterval(3600), sevenDayResetsAt: .now.addingTimeInterval(86400))),
                WidgetAgentUsage(id: "codex", name: "Codex", usage: nil),
                WidgetAgentUsage(id: "acp", name: "ACP Client", usage: nil, supportsLimits: false)
            ]))
    }
}

#Preview(as: .systemMedium) { ProjectTasksWidget() } timeline: { DesktopWidgetEntry.preview }
#Preview(as: .systemLarge) { AgentUsageWidget() } timeline: { DesktopWidgetEntry.preview }
