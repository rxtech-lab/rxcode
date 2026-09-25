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
                        .help("Remove")
                    }

                    if steerDeclinedIDs.contains(queued.id) {
                        Text("Couldn't reach the current response — still queued, sends when it ends.")
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
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// Attachments are never steered — the encoding differs per provider and a
    /// silently dropped image is worse than one that waits — so a message
    /// carrying any gets the plain interrupt button.
    func canSteer(_ queued: QueuedMessage) -> Bool {
        chatBridge.canSteer && queued.attachments.isEmpty
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
        if canSteer(queued) {
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
            .disabled(chatBridge.hasPendingPlanDecision)
            .help("Send before the current response ends — steer it in, or interrupt")
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
            .disabled(chatBridge.hasPendingPlanDecision)
            .help("Send now — cancels current response")
        }
    }

    var queuedHeader: some View {
        HStack(spacing: 8) {
            Text("\(windowState.messageQueue.count) messages queued")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Spacer(minLength: 0)

            if windowState.messageQueue.allSatisfy(canSteer) {
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
                .disabled(chatBridge.hasPendingPlanDecision)
                .help("Combine every queued message and send it as a single turn")
            } else {
                Button {
                    sendAllQueuedAsOne()
                } label: {
                    sendAllLabel
                }
                .buttonStyle(.plain)
                .disabled(chatBridge.hasPendingPlanDecision)
                .help("Combine and send all queued messages as a single turn")
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
        .foregroundStyle(ClaudeTheme.accent)
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
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil),
               let attachment = AttachmentFactory.fromFileURL(url) {
                DispatchQueue.main.async { windowState.addAttachment(attachment) }
                return
            }
            // Inlined (not factored into loadImageDataAsAttachment) to keep `provider` within
            // this nonisolated closure — passing it to a MainActor method violates Sendable.
            guard provider.hasRepresentationConforming(toTypeIdentifier: UTType.image.identifier) else { return }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                let name = "drop-\(UUID().uuidString.prefix(8)).png"
                let attachment = Attachment(type: .image, name: name, imageData: data)
                DispatchQueue.main.async { windowState.addAttachment(attachment) }
            }
        }
    }

    func loadImageDataAsAttachment(from provider: NSItemProvider) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            let name = "drop-\(UUID().uuidString.prefix(8)).png"
            let attachment = Attachment(type: .image, name: name, imageData: data)
            DispatchQueue.main.async { windowState.addAttachment(attachment) }
        }
    }

    func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            if let attachment = AttachmentFactory.fromFileURL(url) {
                windowState.addAttachment(attachment)
            }
        }
    }
}
#endif
