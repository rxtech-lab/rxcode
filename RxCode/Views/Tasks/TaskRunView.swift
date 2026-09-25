import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// The task form's Run tab: what the agent was asked, what it answered, and
/// any follow-ups, read from the task's thread. A composer at the bottom
/// continues the same thread, and accepts pasted or dropped images and files.
struct TaskRunView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let taskId: UUID

    @State private var turns: [TaskRunTurn] = []
    @State private var hasThread = true
    @State private var isLoading = true
    @State private var followUp = ""
    @State private var followUpAttachments: [Attachment] = []
    @State private var isSending = false
    @State private var isDropTargeted = false
    @State private var composerController = MarkdownEditorController()
    @State private var isComposerFocused = false
    @State private var composerHasMarkedText = false
    @State private var previewImage: Attachment?
    @State private var transcriptHeight: CGFloat = 0
    @State private var latestTurnHeight: CGFloat = 0
    @State private var measuredTurnID: Int?

    private var task: ProjectTask? { appState.task(id: taskId) }

    /// Whether the task's thread is streaming right now. Read from
    /// `sessionActivity` (not `sessionStates`) so this view doesn't re-render on
    /// every streamed token.
    private var isAgentRunning: Bool {
        task.map(appState.isAgentRunning(for:)) ?? false
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
        .sheet(item: $previewImage) { ImagePreviewSheet(attachment: $0) }
        // Reload when a run starts or ends, or the task changes column.
        .task(id: "\(task?.status.rawValue ?? "")|\(isAgentRunning)|\(task?.sessionKey ?? "")") {
            await reload()
        }
    }

    // MARK: - Status

    private func statusBar(_ task: ProjectTask) -> some View {
        HStack(spacing: 8) {
            TaskStatusIcon(status: task.status, board: appState.taskBoard(for: task.projectId), size: 12)
            Text(appState.column(for: task).name)
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
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(turns) { turn in
                            turnView(turn, isLast: turn.id == turns.last?.id)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    if turn.id == turns.last?.id {
                                        latestTurnHeight = height
                                        measuredTurnID = turn.id
                                    }
                                }
                                .id(turn.id)
                        }
                        // Keep the newest prompt at the top while its response is short.
                        // The space gives way to the response as the turn grows.
                        Color.clear.frame(height: tailSpacerHeight)
                        Color.clear.frame(height: 20)
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    transcriptHeight = height
                }
                .task(id: turns.last?.id) {
                    guard let last = turns.last?.id else { return }
                    // Wait for the new turn and its trailing space to enter layout.
                    for _ in 0..<10 {
                        if measuredTurnID == last, transcriptHeight > 0 { break }
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(last, anchor: .top)
                }
            }
        }
    }

    private var tailSpacerHeight: CGFloat {
        let measuredHeight = measuredTurnID == turns.last?.id ? latestTurnHeight : 0
        return max(0, transcriptHeight - measuredHeight - 20)
    }

    private func turnView(_ turn: TaskRunTurn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(turn.id == 0 ? "Task" : "Follow-up", systemImage: turn.id == 0 ? "checklist" : "arrowshape.turn.up.right")
                TaskPromptView(content: TaskPromptContent.parse(turn.prompt))
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
        let canCompose = hasThread && !appState.isStatusLocked(task) && !isAgentRunning
        let hasContent = !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !followUpAttachments.isEmpty
        let canSend = canCompose && !isSending && hasContent
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
        return VStack(alignment: .leading, spacing: 8) {
            // Images are chips inside the text; the row holds everything else.
            if followUpAttachments.contains(where: { $0.type != .image }) {
                FlowLayout(spacing: 6) {
                    ForEach(followUpAttachments.filter { $0.type != .image }) { attachment in
                        attachmentChip(attachment, isRemovable: canCompose)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                followUpField(task, isEditable: canCompose) {
                    guard canSend else { return false }
                    send(task)
                    return true
                }

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: shape)
        .overlay {
            if isDropTargeted, canCompose {
                shape
                    .strokeBorder(ClaudeTheme.accent, lineWidth: 1.5)
                    .background(shape.fill(ClaudeTheme.accent.opacity(0.08)))
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accent)
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: AttachmentIntake.dropTypes, isTargeted: $isDropTargeted) { providers in
            guard canCompose else { return false }
            AttachmentIntake.load(
                providers,
                onAttachment: addFollowUpAttachment,
                onText: { [composerController] text in composerController.insert(text) }
            )
            return true
        }
        .padding(16)
    }

    /// A 1–5 line field: the hidden `Text` sizes it, the chat input's text view
    /// sits on top and scrolls past five lines. Each pasted or dropped image is
    /// an `[ImageN]` chip, N being its place among the image attachments.
    private func followUpField(
        _ task: ProjectTask,
        isEditable: Bool,
        onReturn: @escaping () -> Bool
    ) -> some View {
        let fontSize = ClaudeTheme.size(13)
        return Text(followUp.isEmpty || followUp.hasSuffix("\n") ? followUp + " " : followUp)
            .font(.system(size: fontSize))
            .lineLimit(1...5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                IMETextView(
                    text: $followUp,
                    isFocused: $isComposerFocused,
                    hasMarkedText: $composerHasMarkedText,
                    font: .systemFont(ofSize: fontSize),
                    textColor: NSColor(isEditable ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary),
                    placeholder: composerPrompt(task),
                    onReturn: { [composerController] in
                        if !onReturn() { composerController.insert("\n") }
                    },
                    onPasteCommandV: {
                        guard isEditable else { return true }
                        guard let pasted = AttachmentIntake.attachments(from: .general) else { return false }
                        pasted.forEach(addFollowUpAttachment)
                        return true
                    },
                    onImageChipTap: { index in previewImage = followUpImage(at: index) },
                    isEditable: isEditable,
                    accessibilityIdentifier: "task-run-follow-up",
                    onTextViewReady: { [composerController] textView in
                        // Let dropped files reach the composer's SwiftUI drop target.
                        textView.unregisterDraggedTypes()
                        composerController.textView = textView
                    },
                    chipThumbnail: { index in
                        followUpImage(at: index).flatMap(ChipThumbnailCache.shared.thumbnail(for:))
                    }
                )
            }
    }

    private func attachmentChip(_ attachment: Attachment, isRemovable: Bool) -> some View {
        let icon: String = switch attachment.type {
        case .image: "photo"
        case .link: "link"
        case .text: "doc.plaintext"
        case .file: "doc"
        }
        return HStack(spacing: 4) {
            Label(attachment.name, systemImage: icon)
                .lineLimit(1)
                .truncationMode(.middle)
            if isRemovable {
                Button {
                    followUpAttachments.removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(9), weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove attachment")
            }
        }
        .font(.system(size: ClaudeTheme.size(11)))
        .foregroundStyle(ClaudeTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(ClaudeTheme.surfaceElevated))
        .help(attachment.path.isEmpty ? attachment.name : attachment.path)
    }

    private func addFollowUpAttachment(_ attachment: Attachment) {
        guard attachment.path.isEmpty
            || !followUpAttachments.contains(where: { $0.path == attachment.path })
        else { return }
        followUpAttachments.append(attachment)
        if attachment.type == .image {
            composerController.insert("[Image\(followUpImages.count)]")
        }
    }

    private var followUpImages: [Attachment] {
        followUpAttachments.filter { $0.type == .image }
    }

    /// The image behind an `[ImageN]` chip (1-based).
    private func followUpImage(at index: Int) -> Attachment? {
        let images = followUpImages
        return images.indices.contains(index - 1) ? images[index - 1] : nil
    }

    private func composerPrompt(_ task: ProjectTask) -> String {
        if !hasThread { return String(localized: "No thread to follow up in") }
        if appState.isStatusLocked(task) || isAgentRunning { return String(localized: "Wait for the agent to finish…") }
        return String(localized: "Ask the agent for a follow-up…")
    }

    private func send(_ task: ProjectTask) {
        let text = followUp
        // An image whose chip was deleted from the text is dropped from the send.
        let images = followUpImages
        let attachments = followUpAttachments.filter { attachment in
            guard attachment.type == .image,
                  let index = images.firstIndex(where: { $0.id == attachment.id })
            else { return true }
            return text.contains("[Image\(index + 1)]")
        }
        isSending = true
        Task {
            if await appState.sendTaskFollowUp(task, text: text, attachments: attachments) {
                followUp = ""
                followUpAttachments = []
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
