import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// The task form's Run tab: what the agent was asked, what it answered, and
/// any follow-ups, read from the task's thread. A composer at the bottom
/// continues the same thread.
struct TaskRunView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let taskId: UUID

    @State private var turns: [TaskRunTurn] = []
    @State private var hasThread = true
    @State private var isLoading = true
    @State private var followUp = ""
    @State private var isSending = false

    private var task: ProjectTask? { appState.task(id: taskId) }

    /// Whether the task's thread is streaming right now. Read from
    /// `sessionActivity` (not `sessionStates`) so this view doesn't re-render on
    /// every streamed token.
    private var isAgentRunning: Bool {
        guard let key = task?.sessionKey else { return false }
        return appState.sessionActivity[appState.resolveCurrentSessionId(key)]?.isStreaming ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            if let task {
                statusBar(task)
                ClaudeThemeDivider()
                content(task)
                ClaudeThemeDivider()
                composer(task)
            }
        }
        // Reload when a run starts or ends, or the task changes column.
        .task(id: "\(task?.status.rawValue ?? "")|\(isAgentRunning)|\(task?.sessionKey ?? "")") {
            await reload()
        }
    }

    // MARK: - Status

    private func statusBar(_ task: ProjectTask) -> some View {
        HStack(spacing: 8) {
            TaskStatusIcon(status: task.status, size: 12)
            Text(task.status.displayName)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
            if task.agent.isAssigned {
                TaskPill(text: appState.taskAgentLabel(task.agent), icon: "sparkles", tint: ClaudeTheme.statusRunning)
            }
            Spacer()
            if appState.canOpenChat(for: task) {
                Button {
                    dismiss()
                    appState.openChat(for: task, in: windowState)
                } label: {
                    Label("Open Chat", systemImage: "bubble.left")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Turns

    @ViewBuilder
    private func content(_ task: ProjectTask) -> some View {
        if isLoading, turns.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasThread {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.system(size: ClaudeTheme.size(22)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text("This task has no chat thread.")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text("It was moved here by hand, or its thread was deleted.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(turns) { turn in
                            turnView(turn, isLast: turn.id == turns.last?.id)
                                .id(turn.id)
                        }
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .onChange(of: turns) { _, newValue in
                    if let last = newValue.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = turns.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func turnView(_ turn: TaskRunTurn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(turn.id == 0 ? "Task" : "Follow-up", systemImage: turn.id == 0 ? "checklist" : "arrowshape.turn.up.right")
                MarkdownContentView(text: turn.prompt)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                            .fill(ClaudeTheme.surfaceSecondary)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Agent Response", systemImage: "sparkles")
                if !turn.response.isEmpty {
                    MarkdownContentView(text: turn.response)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
                } else if isLast, isAgentRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("The agent is working…")
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(turn.didError ? "The run ended with an error. Open the chat for details." : "No response text.")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(turn.didError ? ClaudeTheme.statusError : ClaudeTheme.textTertiary)
                }
            }
        }
    }

    private func sectionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
            .foregroundStyle(ClaudeTheme.textTertiary)
    }

    // MARK: - Follow-up

    private func composer(_ task: ProjectTask) -> some View {
        let canSend = hasThread && !task.isStatusLocked && !isAgentRunning && !isSending
            && !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Follow-up",
                text: $followUp,
                prompt: Text(composerPrompt(task)),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: ClaudeTheme.size(13)))
            .lineLimit(1...5)
            .disabled(!hasThread || task.isStatusLocked || isAgentRunning)
            .onSubmit { if canSend { send(task) } }
            .accessibilityIdentifier("task-run-follow-up")

            Button {
                send(task)
            } label: {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: ClaudeTheme.size(12), weight: .bold))
                }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .help("Send the follow-up to this task's thread")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        .padding(16)
    }

    private func composerPrompt(_ task: ProjectTask) -> String {
        if !hasThread { return String(localized: "No thread to follow up in") }
        if task.isStatusLocked || isAgentRunning { return String(localized: "Wait for the agent to finish…") }
        return String(localized: "Ask the agent for a follow-up…")
    }

    private func send(_ task: ProjectTask) {
        let text = followUp
        isSending = true
        Task {
            if await appState.sendTaskFollowUp(task, text: text) {
                followUp = ""
            }
            isSending = false
            await reload()
        }
    }

    private func reload() async {
        guard let task else { return }
        isLoading = true
        defer { isLoading = false }
        guard let messages = await appState.taskRunMessages(for: task) else {
            hasThread = false
            turns = []
            return
        }
        hasThread = true
        turns = TaskRunTurn.turns(from: messages)
    }
}
