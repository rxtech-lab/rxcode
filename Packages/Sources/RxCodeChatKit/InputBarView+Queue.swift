import SwiftUI
import TipKit
import UniformTypeIdentifiers
import RxCodeCore

#if os(macOS)

extension InputBarView {
    // MARK: - Queued Message Previews

    var queuedMessagePreviews: some View {
        VStack(spacing: 6) {
            if windowState.messageQueue.count >= 2 {
                queuedHeader
            }
            ForEach(windowState.messageQueue) { queued in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .padding(.top, 2)

                        Text(queuedDisplayText(queued))
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        queuedSendControl(for: queued)

                        Button {
                            removeQueuedMessage(queued.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(chatBridge.queueDispatchInProgress)
                        .help("Remove")
                    }

                    if steerDeclinedIDs.contains(queued.id) {
                        Text("This instruction is still queued.")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .padding(.leading, 21)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                        .fill(ClaudeTheme.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                        .strokeBorder(ClaudeTheme.inputBorder, lineWidth: 1)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if chatBridge.queueDispatchInProgress {
                ProgressView()
                    .controlSize(.small)
                    .padding(7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 14)
                    .accessibilityLabel("Sending queued instruction")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var queuedSendDisabled: Bool {
        chatBridge.queueDispatchInProgress || (chatBridge.agentProvider != .acp && chatBridge.hasPendingPlanDecision)
    }

    /// The per-message "when should this go out?" control.
    ///
    /// Leaving it alone is the third option and the default: the message waits
    /// for the running response to finish. The menu is for overriding that —
    /// steering it into the response that is already running, or interrupting
    /// that response outright. Agents that can't take mid-turn input get the
    /// plain interrupt button instead of a one-item menu.
    @ViewBuilder
    func queuedSendControl(for queued: QueuedMessage) -> some View {
        if chatBridge.canSteer {
            Menu {
                Button {
                    steerQueuedMessage(queued.id)
                } label: {
                    Label("Steer into current response", systemImage: "arrow.turn.down.right")
                }
                Button {
                    sendQueuedNow(queued.id)
                } label: {
                    Label("Interrupt and send now", systemImage: "paperplane.fill")
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .disabled(queuedSendDisabled)
            .help("Steer the current response or interrupt and send")
        } else {
            Button {
                sendQueuedNow(queued.id)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(queuedSendDisabled)
            .accessibilityLabel("Interrupt and send now")
            .help(chatBridge.agentProvider == .acp
                ? "Interrupt and send now. This ACP response has no compatible steering capability."
                : "Interrupt the current response and send now")
        }
    }

    var queuedHeader: some View {
        HStack(spacing: 8) {
            Text("\(windowState.messageQueue.count) messages queued")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Spacer(minLength: 0)

            if chatBridge.canSteer {
                Menu {
                    Button {
                        steerAllQueuedAsOne()
                    } label: {
                        Label("Steer all into current response", systemImage: "arrow.turn.down.right")
                    }
                    Button {
                        sendAllQueuedAsOne()
                    } label: {
                        Label("Interrupt and send all now", systemImage: "paperplane.fill")
                    }
                } label: {
                    sendAllLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(queuedSendDisabled)
                .help("Combine every queued message and send it as a single turn")
            } else {
                Button {
                    sendAllQueuedAsOne()
                } label: {
                    sendAllLabel
                }
                .buttonStyle(.plain)
                .disabled(queuedSendDisabled)
                .accessibilityLabel("Interrupt and send all now")
                .help("Interrupt the current response and send the queued messages as one turn")
            }
        }
        .padding(.horizontal, 4)
    }

    private var sendAllLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            Text("Send all as one")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        }
        .foregroundStyle(ClaudeTheme.accentText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ClaudeTheme.accentSubtle, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(ClaudeTheme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    func removeQueuedMessage(_ id: UUID) {
        steerDeclinedIDs.remove(id)
        withAnimation(.easeOut(duration: 0.15)) {
            chatBridge.removeQueuedMessage(id: id)
        }
    }

    func sendQueuedNow(_ id: UUID) {
        steerDeclinedIDs.remove(id)
        chatBridge.markUserSendRequested()
        Task { await chatBridge.sendQueuedNow(id: id) }
    }

    func sendAllQueuedAsOne() {
        steerDeclinedIDs.removeAll()
        chatBridge.markUserSendRequested()
        Task { await chatBridge.sendAllQueuedAsOne() }
    }

    /// Steering can come back empty-handed — the response may have ended between
    /// the click and the write. The message is still queued when that happens,
    /// so the row says so rather than looking like the click did nothing.
    func steerQueuedMessage(_ id: UUID) {
        chatBridge.markUserSendRequested()
        Task {
            let steered = await chatBridge.steerQueuedMessage(id: id)
            guard !steered, windowState.messageQueue.contains(where: { $0.id == id }) else {
                steerDeclinedIDs.remove(id)
                return
            }
            withAnimation(.easeOut(duration: 0.15)) {
                _ = steerDeclinedIDs.insert(id)
            }
        }
    }

    func steerAllQueuedAsOne() {
        chatBridge.markUserSendRequested()
        Task {
            let steered = await chatBridge.steerAllQueuedAsOne()
            guard !steered else {
                steerDeclinedIDs.removeAll()
                return
            }
            let stillQueued = Set(windowState.messageQueue.map(\.id))
            withAnimation(.easeOut(duration: 0.15)) {
                steerDeclinedIDs.formUnion(stillQueued)
            }
        }
    }

    func queuedDisplayText(_ queued: QueuedMessage) -> String {
        let parts = queued.attachments.map { $0.path.isEmpty ? $0.name : $0.path }
        if queued.text.isEmpty { return parts.joined(separator: "\n") }
        if parts.isEmpty { return queued.text }
        return ([queued.text] + parts).joined(separator: "\n")
    }

    // MARK: - Paste & File Import

    func processItemProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasRepresentationConforming(toTypeIdentifier: UTType.fileURL.identifier) {
                loadFileURLAsAttachment(from: provider)
            } else if provider.hasRepresentationConforming(toTypeIdentifier: UTType.image.identifier) {
                loadImageDataAsAttachment(from: provider)
            }
        }
    }

    func loadFileURLAsAttachment(from provider: NSItemProvider) {
        Task { @MainActor in
            let attachment = await withCheckedContinuation { (continuation: CheckedContinuation<Attachment?, Never>) in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let attachment = (item as? Data)
                        .flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        .flatMap { AttachmentFactory.fromFileURL($0) }
                    continuation.resume(returning: attachment)
                }
            }
            if let attachment {
                addComposerAttachment(attachment)
            } else if provider.hasRepresentationConforming(toTypeIdentifier: UTType.image.identifier) {
                loadImageDataAsAttachment(from: provider)
            }
        }
    }

    func loadImageDataAsAttachment(from provider: NSItemProvider) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            let name = "drop-\(UUID().uuidString.prefix(8)).png"
            let attachment = Attachment(type: .image, name: name, imageData: data)
            DispatchQueue.main.async { addComposerAttachment(attachment) }
        }
    }

    func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            if let attachment = AttachmentFactory.fromFileURL(url) {
                addComposerAttachment(attachment)
            }
        }
    }
}
#endif
