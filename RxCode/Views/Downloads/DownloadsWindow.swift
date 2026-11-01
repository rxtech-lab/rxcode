import AppKit
import RxCodeCore
import SwiftUI

/// Opens the Downloads window whenever a new download or install starts.
/// Attached to every scene, so it works from Settings and onboarding too;
/// `Window` is single-instance, so several presenters reacting is harmless.
struct DownloadWindowPresenter: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private let center = DownloadCenter.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: center.presentRequest) { _, _ in
                openWindow(id: DownloadsWindow.id)
            }
    }
}

/// Download and install progress for agent CLIs, ACP agents, local models and
/// model runtimes, in a window of its own.
struct DownloadsWindow: View {
    static let id = "downloads-window"

    private let center = DownloadCenter.shared
    @State private var pendingCancel: DownloadCenter.Item?
    @State private var confirmCancelAll = false
    @State private var pendingDelete: DownloadCenter.Item?
    @State private var actionStatus: String?
    @State private var actionError: String?

    private func resume(_ item: DownloadCenter.Item) {
        guard let recovery = item.recovery else { return }
        actionStatus = "Resuming download…"
        Task {
            do { try await LocalModelStore.shared.download(summary: recovery.summary, variant: recovery.variant) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func delete(_ item: DownloadCenter.Item) {
        guard let recovery = item.recovery else { return }
        actionStatus = "Deleting download…"
        Task {
            do {
                try await Task.detached {
                    if FileManager.default.fileExists(atPath: recovery.stagingDirectory.path) {
                        try FileManager.default.removeItem(at: recovery.stagingDirectory)
                    }
                }.value
                center.remove(item.id)
                actionStatus = "Download deleted"
            } catch { actionStatus = nil; actionError = error.localizedDescription }
        }
    }

    var body: some View {
        Group {
            if center.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Agent, ACP client and local model downloads appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(center.items) { item in
                        DownloadItemRow(
                            item: item,
                            isCancellable: center.isCancellable(item.id),
                            onCancel: { pendingCancel = item },
                            onRemove: { center.remove(item.id) },
                            onResume: { resume(item) },
                            onDelete: { pendingDelete = item }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: center.persistenceError) { _, error in
            if let error { actionError = "Could not save download history: \(error)" }
        }
        .navigationTitle(center.activeCount > 0 ? "Downloads (\(center.activeCount))" : "Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Cancel All", role: .destructive) { confirmCancelAll = true }
                    .disabled(center.activeCount == 0)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Completed") { center.clearCompleted() }
                    .disabled(!center.items.contains { !$0.phase.isActive })
            }
        }
        .overlay(alignment: .bottom) {
            if let actionStatus {
                Text(actionStatus).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                    .task(id: actionStatus) {
                        try? await Task.sleep(for: .seconds(3))
                        self.actionStatus = nil
                    }
            }
        }
        .alert("Download Action Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .confirmationDialog("Delete unfinished download?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { item in
            Button("Delete Download", role: .destructive) { delete(item); pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("Delete the retained files for “\(item.title)”? Installed models are kept.")
        }
        .confirmationDialog(
            "Cancel this download?",
            isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }),
            presenting: pendingCancel
        ) { item in
            Button("Cancel Download", role: .destructive) {
                center.cancel(item.id)
                pendingCancel = nil
            }
            Button("Keep Downloading", role: .cancel) { pendingCancel = nil }
        } message: { item in
            Text("“\(item.title)” will stop. Model download files are kept so you can resume later.")
        }
        .confirmationDialog("Cancel all downloads?", isPresented: $confirmCancelAll) {
            Button("Cancel All Downloads", role: .destructive) { center.cancelAll() }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("\(center.activeCount) downloads and installs will stop. Model download files are kept so you can resume later.")
        }
    }
}

private struct DownloadItemRow: View {
    let item: DownloadCenter.Item
    let isCancellable: Bool
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: ClaudeTheme.size(16)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .lineLimit(1)
                    Text(item.kind.label)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
                if item.phase.isActive {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                HStack(spacing: 6) {
                    Text(statusText)
                    if item.phase == .downloading {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let speed = DownloadCenter.shared.bytesPerSecond(item.id, at: context.date) {
                                Text("· \(ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max / 2))), countStyle: .file))/s")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let recovery = item.recovery {
                Menu {
                    Button("Show in Finder") {
                        let url = item.phase == .finished ? recovery.directory : recovery.stagingDirectory
                        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: url.path) ? url : recovery.directory])
                    }
                    if !item.phase.isActive && item.phase != .finished {
                        Button("Resume Download", action: onResume)
                        Button("Delete Download…", role: .destructive, action: onDelete)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if item.phase.isActive {
                if isCancellable {
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                }
            } else if item.recovery == nil || item.phase == .finished {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from list")
            }
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch item.phase {
        case .preparing:
            return String(localized: "Preparing…")
        case .downloading:
            let received = LocalModelFormat.bytes(item.receivedBytes)
            if let total = item.totalBytes {
                return String(localized: "Downloading · \(received) of \(LocalModelFormat.bytes(total))")
            }
            return item.receivedBytes > 0 ? String(localized: "Downloading · \(received)") : String(localized: "Downloading…")
        case .installing:
            return String(localized: "Installing…")
        case .finished:
            return String(localized: "Installed")
        case .failed(let message):
            return String(localized: "Failed: \(message)")
        case .interrupted:
            return item.recovery == nil ? "Interrupted — restart from its installer" : "Interrupted — ready to resume"
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    private var statusColor: Color {
        switch item.phase {
        case .finished: ClaudeTheme.statusSuccess
        case .failed: ClaudeTheme.statusError
        default: .secondary
        }
    }
}
