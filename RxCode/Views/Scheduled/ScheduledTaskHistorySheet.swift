import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// A scheduled task's past runs, newest first. Selecting a run pushes its
/// agent log: the prompt, the agent's messages, and the tools it called.
struct ScheduledTaskHistorySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let taskId: UUID
    /// Opens a run's thread in the main window; the sheet dismisses first.
    let onOpenThread: (String) -> Void

    private var task: ScheduledTask? {
        appState.scheduledTasks.first { $0.id == taskId }
    }

    private var runs: [ScheduledTaskRun] {
        appState.scheduledTaskRuns(for: taskId)
    }

    private var isRunning: Bool {
        appState.isScheduledTaskRunning(taskId)
    }

    private var canRun: Bool {
        guard let task, !isRunning else { return false }
        return task.projectId.map { id in appState.projects.contains { $0.id == id } } ?? true
    }

    /// The run whose log is pushed over the list; `nil` shows the list.
    @State private var selectedRunId: UUID?

    private var title: String {
        guard let name = task?.name, !name.isEmpty else { return String(localized: "Run History") }
        return name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            Group {
                if let selectedRunId {
                    ScheduledTaskRunLogView(runId: selectedRunId, onOpenThread: open)
                        .transition(.move(edge: .trailing))
                } else if runs.isEmpty {
                    emptyState
                } else {
                    List(runs) { run in
                        Button {
                            withAnimation(.snappy) { selectedRunId = run.id }
                        } label: {
                            HStack {
                                ScheduledTaskRunRow(run: run)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                    .foregroundStyle(ClaudeTheme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ClaudeThemeDivider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, maxHeight: .infinity, alignment: .top)
        .background(ClaudeTheme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if selectedRunId != nil {
                Button {
                    withAnimation(.snappy) { selectedRunId = nil }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to run history")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                Text(selectedRunId == nil ? String(localized: "Run History") : String(localized: "Run Log"))
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                guard let task else { return }
                Task { await appState.runScheduledTask(task, trigger: .manual) }
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
            .help(isRunning ? "This task is already running" : "Start a run of this task now")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Runs Yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Each run of this task and the agent's log will show here.")
        }
    }

    private func open(_ sessionId: String) {
        dismiss()
        onOpenThread(sessionId)
    }
}

// MARK: - Run Row

private struct ScheduledTaskRunRow: View {
    let run: ScheduledTaskRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScheduledTaskRunStatusIcon(status: run.status)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    ScheduledTaskRunMeta(run: run)
                }
                if let detail = run.errorMessage ?? run.summary {
                    Text(detail)
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(run.errorMessage != nil ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Trigger, status, and duration of a run, as one line of small labels.
private struct ScheduledTaskRunMeta: View {
    let run: ScheduledTaskRun

    var body: some View {
        HStack(spacing: 8) {
            Text(run.status.title)
                .foregroundStyle(run.status.tint)
            Label(run.trigger.title, systemImage: run.trigger == .manual ? "hand.tap" : "clock")
            if let duration = run.duration {
                Label(
                    Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)),
                    systemImage: "timer"
                )
            }
        }
        .font(.system(size: ClaudeTheme.size(11)))
        .foregroundStyle(ClaudeTheme.textTertiary)
        .labelStyle(.titleAndIcon)
    }
}

private struct ScheduledTaskRunStatusIcon: View {
    let status: ScheduledTaskRun.Status

    var body: some View {
        if status == .running {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: status.systemImage)
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(status.tint)
        }
    }
}

// MARK: - Run Log

/// One run's agent log, read from its chat thread. Live while the run is
/// still streaming.
private struct ScheduledTaskRunLogView: View {
    @Environment(AppState.self) private var appState

    let runId: UUID
    let onOpenThread: (String) -> Void

    @State private var messages: [ChatMessage] = []
    @State private var hasThread = true
    @State private var isLoading = true
    @State private var followUp = ""
    @State private var isSending = false
    @State private var sendFailed = false
    @FocusState private var isComposerFocused: Bool

    private var isAgentResponding: Bool {
        run.map(appState.isScheduledTaskRunStreaming) ?? false
    }

    private var run: ScheduledTaskRun? {
        appState.scheduledTaskRuns.first { $0.id == runId }
    }

    /// Messages straight from memory once the thread is loaded, so a running
    /// run or a follow-up reply grows in place.
    private var liveMessages: [ChatMessage]? {
        guard let sessionId = run.flatMap(appState.resolvedSessionKey(for:)),
              let messages = appState.sessionStates[sessionId]?.messages,
              !messages.isEmpty
        else { return nil }
        return messages
    }

    var body: some View {
        Group {
            if let run {
                VStack(spacing: 0) {
                    content(run)
                    if hasThread, run.sessionKey != nil {
                        ClaudeThemeDivider()
                        composer(run)
                    }
                }
            } else {
                ContentUnavailableView("Run Not Found", systemImage: "questionmark.circle")
            }
        }
        .task(id: run?.status) { await reload() }
    }

    @ViewBuilder
    private func content(_ run: ScheduledTaskRun) -> some View {
        let shown = liveMessages ?? messages
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(run)
                    if let error = run.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.statusError)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                                    .fill(ClaudeTheme.statusError.opacity(0.08))
                            )
                    }
                    if isLoading, shown.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if shown.isEmpty {
                        missingThread(run)
                    } else {
                        ForEach(shown) { message in
                            ScheduledTaskLogMessage(message: message)
                        }
                        if run.status == .running || isAgentResponding {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("The agent is working…")
                                    .font(.system(size: ClaudeTheme.size(12)))
                                    .foregroundStyle(ClaudeTheme.textSecondary)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follow the conversation as messages arrive.
            .onChange(of: shown.count) {
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }

    private static let bottomID = "scheduled-run-log-bottom"

    // MARK: - Follow-up

    private func composer(_ run: ScheduledTaskRun) -> some View {
        let canSend = !isSending && !isAgentResponding
            && !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            if sendFailed {
                Label("Couldn't send the message. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    isAgentResponding
                        ? String(localized: "Wait for the agent to finish…")
                        : String(localized: "Ask the agent about this run…"),
                    text: $followUp,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: ClaudeTheme.size(13)))
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .onSubmit { if canSend { send(run) } }
                .padding(.vertical, 4)

                Button {
                    send(run)
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
                .help(isAgentResponding ? "Wait for the agent to finish responding" : "Send a follow-up to this run's thread")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func send(_ run: ScheduledTaskRun) {
        let text = followUp
        isSending = true
        sendFailed = false
        Task {
            if await appState.sendScheduledTaskRunFollowUp(run, text: text) {
                followUp = ""
            } else {
                sendFailed = true
            }
            isSending = false
        }
    }

    private func header(_ run: ScheduledTaskRun) -> some View {
        HStack(spacing: 10) {
            ScheduledTaskRunStatusIcon(status: run.status)
            Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            ScheduledTaskRunMeta(run: run)
            Spacer(minLength: 0)
            if let sessionId = appState.resolvedSessionKey(for: run), hasThread {
                Button {
                    onOpenThread(sessionId)
                } label: {
                    Label("Open Thread", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Open this run's chat thread")
            }
        }
    }

    /// The thread is gone; fall back to the final message stored with the run.
    @ViewBuilder
    private func missingThread(_ run: ScheduledTaskRun) -> some View {
        if let summary = run.summary {
            VStack(alignment: .leading, spacing: 6) {
                Label("Final Message", systemImage: "sparkles")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                MarkdownContentView(text: summary)
                Text("The full log isn't available because this run's thread was deleted.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        } else {
            ContentUnavailableView(
                "No Log",
                systemImage: "doc.text.magnifyingglass",
                description: Text("This run has no chat thread, or it was deleted.")
            )
        }
    }

    private func reload() async {
        guard let run else { return }
        isLoading = true
        defer { isLoading = false }
        if let loaded = await appState.scheduledTaskRunMessages(run) {
            messages = loaded
            hasThread = true
        } else {
            messages = []
            hasThread = false
        }
    }
}

// MARK: - Log Message

/// One transcript message: the prompt, the agent's text as markdown, its tool
/// calls as collapsible rows, or an error.
private struct ScheduledTaskLogMessage: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            let text = ChatSession.extractDisplayedContent(from: message.content).text
            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Prompt", systemImage: "text.bubble")
                    MarkdownContentView(text: text, style: .rxCodeCompact)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                                .fill(ClaudeTheme.surfaceSecondary)
                        )
                }
            }
        } else if message.isError {
            Label(message.content, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.statusError)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.blocks) { block in
                    if let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        MarkdownContentView(text: text)
                    } else if let toolCall = block.toolCall {
                        ScheduledTaskLogToolRow(toolCall: toolCall)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
            .foregroundStyle(ClaudeTheme.textTertiary)
    }
}

private struct ScheduledTaskLogToolRow: View {
    let toolCall: ToolCall

    @State private var isExpanded = false

    /// The tool's most telling argument, on one line.
    private var argument: String? {
        for key in ["description", "command", "file_path", "pattern", "path", "url", "query", "skill"] {
            if let value = toolCall.input[key]?.stringValue, !value.isEmpty {
                return value.split(whereSeparator: \.isNewline).first.map(String.init)
            }
        }
        return nil
    }

    private var displayName: String {
        toolCall.name
            .replacingOccurrences(of: "mcp__", with: "")
            .replacingOccurrences(of: "__", with: " / ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let result = toolCall.result, !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                        .fill(ClaudeTheme.codeBackground)
                )
            } else {
                Text("No output.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolCall.isError ? "xmark.octagon" : "wrench.and.screwdriver")
                    .foregroundStyle(toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.textTertiary)
                Text(displayName)
                    .fontWeight(.medium)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                if let argument {
                    Text(argument)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: ClaudeTheme.size(12)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.borderSubtle)
        )
    }
}

// MARK: - Display

extension ScheduledTaskRun.Status {
    var title: String {
        switch self {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .interrupted: String(localized: "Interrupted")
        }
    }

    var systemImage: String {
        switch self {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: ClaudeTheme.statusRunning
        case .succeeded: ClaudeTheme.statusSuccess
        case .failed: ClaudeTheme.statusError
        case .interrupted: ClaudeTheme.statusWarning
        }
    }
}

extension ScheduledTaskRun.Trigger {
    var title: String {
        switch self {
        case .schedule: String(localized: "Scheduled")
        case .manual: String(localized: "Manual")
        }
    }
}
