import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// A project dashboard backed by the same task snapshot as the board.
struct FlowcyProjectOverview: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.flowcyRemoteActions) private var remoteActions
    let project: CloudProject
    let sections: [FlowcyProjectSection]
    let navigate: (FlowcyProjectSection) -> Void
    let openAction: (FlowcyProjectQuickAction) -> Void
    @State private var loading = false
    @State private var error: String?
    @State private var draft: ProjectTask?

    private var local: Project? { state.taskProjects.first { $0.cloudId == project.id } }
    private var board: TaskBoard? { local.flatMap { state.taskSnapshots[$0.id]?.board } }
    private var tasks: [ProjectTask] { board?.tasks ?? [] }
    private var completed: Int {
        guard let board else { return 0 }
        return tasks.filter { board.column(for: $0.status).countsAsDone }.count
    }
    private var attention: [ProjectTask] {
        guard let board else { return [] }
        return tasks.filter {
            !board.column(for: $0.status).countsAsDone &&
            ($0.attentionReason != nil || $0.priority == .urgent || $0.priority == .high)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let error, board != nil {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let board {
                    progress(board)
                    taskSection("Needs Attention", items: Array(attention.prefix(5)))
                    taskSection("Recently Updated", items: Array(tasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)))
                } else if loading {
                    ProgressView("Loading task overview…").frame(maxWidth: .infinity)
                } else if let error {
                    ContentUnavailableView {
                        Label("Unable to Load Tasks", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Retry") { Task { await reload() } }
                    }.frame(maxWidth: .infinity, minHeight: 240)
                }
                Text("Explore Project").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], spacing: 12) {
                    ForEach(sections.filter { $0 != .overview }) { section in
                        Button {
                            MobileHaptics.buttonTap()
                            navigate(section)
                        } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                Image(systemName: section.icon).font(.title2).foregroundStyle(.tint)
                                Text(section.rawValue).font(.headline).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(20).frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.title)
        .accessibilityIdentifier("flowcy-project-overview")
        .toolbar {
            if project.repositoryFullName != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Create Release", systemImage: "shippingbox") { openAction(.release) }
                        Button("Scan CI", systemImage: "arrow.triangle.2.circlepath") { openAction(.ci) }
                        Button("Scan Dependencies", systemImage: "shippingbox") { openAction(.dependencies) }
                    } label: { Label("Quick Actions", systemImage: "bolt") }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Task", systemImage: "plus") {
                    guard let local else { return }
                    MobileHaptics.buttonTap()
                    draft = state.newTaskDraft(projectID: local.id, story: nil)
                }.disabled(board == nil)
            }
        }
        .sheet(item: $draft) { task in
            NavigationStack { MobileTaskFormView(task: task, isNew: true) }
                .mobileSheetPresentation()
        }
        .refreshable { await reload() }
        .task(id: project.id) { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(project.repositoryFullName ?? "Standalone project", systemImage: "folder")
                .font(.subheadline).foregroundStyle(.secondary)
            if let description = project.description, !description.isEmpty {
                MarkdownContentView(text: description)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progress(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Task Progress").font(.title3.bold())
                Spacer()
                Text("\(completed) of \(tasks.count) complete").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(completed), total: Double(max(tasks.count, 1)))
                .tint(.green)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 16) {
                ForEach(board.effectiveColumns) { column in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(board.tasks(in: column.id).count)").font(.title.bold()).monospacedDigit()
                        Label(column.name, systemImage: column.systemImage)
                            .font(.caption).foregroundStyle(column.tint)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if tasks.isEmpty {
                Text("Create your first task using the + button.").font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(20)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private func taskSection(_ title: String, items: [ProjectTask]) -> some View {
        if !items.isEmpty, let board {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.bold())
                ForEach(items) { task in
                    MobileTaskDetailButton(route: .task(projectID: task.projectId, taskID: task.id), onOpenChat: { _ in remoteActions?.open() }) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: board.column(for: task.status).systemImage)
                                .foregroundStyle(board.column(for: task.status).tint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).font(.headline).lineLimit(2)
                                if let reason = task.attentionReason {
                                    Text(reason).font(.caption).foregroundStyle(.orange)
                                }
                                Text(task.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(16)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            if local == nil { try await state.refreshCloudTaskProjects() }
            guard let local else { throw FlowcyError.message("This project is no longer available.") }
            try await state.loadTaskBoard(projectID: local.id)
        } catch { self.error = error.localizedDescription }
    }
}
