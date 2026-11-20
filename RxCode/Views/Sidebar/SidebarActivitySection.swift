import RxCodeCore
import SwiftUI

struct SidebarRun: Identifiable {
    enum Status {
        case running, verifying, needsApproval, completedUnread

        var title: LocalizedStringResource {
            switch self {
            case .running: "Running"
            case .verifying: "Verifying"
            case .needsApproval: "Needs approval"
            case .completedUnread: "Completed (unread)"
            }
        }
    }

    let id: String
    let project: Project
    let title: String
    let status: Status
    let progress: ChatTodoProgress?
}

extension AppState {
    func sidebarRuns(in window: WindowState) -> [SidebarRun] {
        var statuses: [String: SidebarRun.Status] = [:]
        for (key, activity) in sessionActivity where activity.isStreaming || activity.hasUncheckedCompletion {
            let id = resolveCurrentSessionId(key)
            if activity.isStreaming {
                statuses[id] = .running
            } else if statuses[id] == nil {
                statuses[id] = .completedUnread
            }
        }
        let approvals = window.pendingPermissions.compactMap(\.sessionId) + agentPrompts.confirmations.map(\.sessionKey)
        for key in approvals {
            statuses[resolveCurrentSessionId(key)] = .needsApproval
        }
        guard !statuses.isEmpty else { return [] }

        let projectsByID = Dictionary(uniqueKeysWithValues: sessionProjects.map { ($0.id, $0) })
        return allSessionSummaries.compactMap { summary -> SidebarRun? in
            guard let status = statuses[summary.id], let project = projectsByID[summary.projectId] else { return nil }
            let isCheck = summary.threadLabel == TaskCompletionCheckLabel.inProgress
            let ownerID = resolveCurrentSessionId((isCheck ? summary.parentThreadId : nil) ?? summary.id)
            let task = taskBoards[project.id]?.tasks.first { $0.sessionKey.map(resolveCurrentSessionId) == ownerID }
            let title = ChatSession.stripAttachmentMarkers(from: task?.title ?? summary.title)
            return SidebarRun(
                id: summary.id, project: project, title: title.isEmpty ? ChatSession.defaultTitle : title,
                status: isCheck && status == .running ? .verifying : status,
                progress: todoProgress(forSessionId: summary.id)
            )
        }.sorted { lhs, rhs in
            if (lhs.status == .needsApproval) != (rhs.status == .needsApproval) { return lhs.status == .needsApproval }
            let projectOrder = lhs.project.name.localizedStandardCompare(rhs.project.name)
            if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
        }
    }
}

struct SidebarActivitySection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showAll = false
    @State private var isExpanded = true
    private let previewLimit = 3

    var body: some View {
        let runs = appState.sidebarRuns(in: windowState)
        VStack(spacing: 0) {
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                Text("Active now")
                                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                                Text(runs.count, format: .number)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(ClaudeTheme.accent)
                                    .padding(.horizontal, 6)
                                    .background(ClaudeTheme.accentSubtle, in: Capsule())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar-active-runs")
                        Spacer()
                        if runs.count > previewLimit {
                            Button("Show all") { showAll = true }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)

                    if isExpanded {
                        ForEach(runs.prefix(previewLimit)) { run in
                            runButton(run)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                ClaudeThemeDivider()
            }
        }
        .sheet(isPresented: $showAll) {
            NavigationStack {
                Group {
                    if runs.isEmpty {
                        ContentUnavailableView("No active runs", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(runs) { run in runButton(run, showsSelection: true) }
                            }
                            .padding(12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Active now")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showAll = false }
                    }
                }
            }
            .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 560)
        }
    }

    private func runButton(_ run: SidebarRun, showsSelection: Bool = false) -> some View {
        let isCurrent = showsSelection && (windowState.generalRoute == nil || windowState.generalRoute == .chat)
            && windowState.currentSessionId == run.id
        return SidebarRunButton(run: run, isCurrent: isCurrent) {
            showAll = false
            appState.selectSession(id: appState.resolveCurrentSessionId(run.id), inChatTab: run.project.isGlobalChat, in: windowState)
        }
    }
}

private struct SidebarRunButton: View {
    let run: SidebarRun
    let isCurrent: Bool
    let open: () -> Void
    @State private var isHovered = false

    private var symbol: String {
        switch run.status {
        case .running: "waveform"
        case .verifying: "checkmark.seal"
        case .needsApproval: "hand.raised.fill"
        case .completedUnread: "checkmark.circle.fill"
        }
    }

    var body: some View {
        let tint = switch run.status {
        case .needsApproval: ClaudeTheme.statusWarning
        case .running, .verifying: ClaudeTheme.statusRunning
        case .completedUnread: ClaudeTheme.statusSuccess
        }
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 27, height: 27)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    HStack(spacing: 4) {
                        Text(run.project.name)
                        Text("·")
                        Text(run.status.title)
                            .foregroundStyle(run.status == .needsApproval ? tint : ClaudeTheme.textSecondary)
                            .layoutPriority(1)
                    }
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if let progress = run.progress {
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .accessibilityLabel("\(progress.done) of \(progress.total) steps complete")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isCurrent ? ClaudeTheme.accentSubtle : (isHovered ? ClaudeTheme.surfaceSecondary : .clear), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onHover { isHovered = $0 }
        .help("\(run.title) · \(run.project.name)")
        .accessibilityIdentifier("sidebar-run-\(run.id)")
    }
}
