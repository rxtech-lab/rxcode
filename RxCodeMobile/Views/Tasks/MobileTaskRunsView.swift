import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// The task detail's Runs tab, like the Mac task form's Run tab: what the
/// agent was asked, what it answered, and any follow-ups, read from the
/// task's thread on the desktop. A floating capsule shows the task's column;
/// a toolbar menu continues the thread or opens its chat.
struct MobileTaskRunsView: View {
    @EnvironmentObject private var state: MobileAppState
    let task: ProjectTask
    let onFollowUp: () -> Void
    let onOpenChat: (String) -> Void

    @State private var turns: [TaskRunTurn] = []
    @State private var hasThread = true
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var board: TaskBoard { state.taskBoard(for: task.projectId) }
    private var isAgentRunning: Bool { state.isTaskAgentRunning(task) }
    private var sessionID: String? { state.taskSessionID(task) }

    /// Reload when a run starts or ends, or the task changes column.
    private var reloadKey: String {
        "\(task.status.rawValue)|\(isAgentRunning)|\(task.sessionKey ?? "")|\(sessionID ?? "")"
    }

    var body: some View {
        content
            .toolbar { toolbarContent }
            .overlay(alignment: .bottom) { floatingStatus }
            .task(id: reloadKey) { await reload() }
            .refreshable { await reload() }
            .mobileTaskErrorAlert($errorMessage)
    }

    // MARK: - Turns

    @ViewBuilder
    private var content: some View {
        if isLoading, turns.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasThread {
            ContentUnavailableView(
                "No Runs Yet",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                description: Text(task.agent.isAssigned
                    ? "Run the task with its agent to see what it was asked and what it answered."
                    : "Assign an agent in Config, then run the task.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(turns) { turn in
                            turnView(turn, isLast: turn.id == turns.last?.id)
                                .id(turn.id)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 56)
                }
                .task(id: turns.last?.id) {
                    guard let last = turns.last?.id else { return }
                    proxy.scrollTo(last, anchor: .top)
                }
            }
        }
    }

    private func turnView(_ turn: TaskRunTurn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(
                    turn.id == 0 ? "Task" : "Follow-up",
                    systemImage: turn.id == 0 ? "checklist" : "arrowshape.turn.up.right"
                )
                TaskPromptView(content: TaskPromptContent.parse(turn.prompt))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Agent Response", systemImage: "sparkles")
                if !turn.response.isEmpty {
                    MarkdownContentView(text: turn.response)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                } else if isLast, isAgentRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("The agent is working…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(turn.didError ? "The run ended with an error. Open the chat for details." : "No response text.")
                        .font(.footnote)
                        .foregroundStyle(turn.didError ? Color.red : Color.secondary)
                }
            }
        }
    }

    private func sectionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Floating status

    /// The task's column, floating over the transcript: the column icon, or a
    /// spinner and "Agent working" while its agent is mid-turn.
    private var floatingStatus: some View {
        let column = board.column(for: task.status)
        return HStack(spacing: 8) {
            if isAgentRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: column.systemImage)
                    .foregroundStyle(column.tint)
            }
            Text(column.name)
                .font(.subheadline.weight(.medium))
            if isAgentRunning {
                Text("· Agent working")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-runs-status")
        .animation(.default, value: isAgentRunning)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let canFollowUp = hasThread && sessionID != nil && !board.isStatusLocked(task) && !isAgentRunning
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: onFollowUp) {
                    Label("Follow Up", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(!canFollowUp)
                .accessibilityIdentifier("task-runs-follow-up")
                if let sessionID {
                    Button {
                        onOpenChat(sessionID)
                    } label: {
                        Label("Open Chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityIdentifier("task-runs-open-chat")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Run actions")
            .accessibilityIdentifier("task-runs-actions")
        }
    }

    // MARK: - Loading

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let runs = try await state.fetchTaskRuns(task)
            hasThread = runs != nil
            turns = runs ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
