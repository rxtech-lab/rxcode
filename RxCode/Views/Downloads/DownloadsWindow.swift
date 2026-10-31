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
                            onRemove: { center.remove(item.id) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("“\(item.title)” will stop and its partial files will be removed.")
        }
        .confirmationDialog("Cancel all downloads?", isPresented: $confirmCancelAll) {
            Button("Cancel All Downloads", role: .destructive) { center.cancelAll() }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("\(center.activeCount) downloads and installs will stop and their partial files will be removed.")
        }
    }
}

private struct DownloadItemRow: View {
    let item: DownloadCenter.Item
    let isCancellable: Bool
    let onCancel: () -> Void
    let onRemove: () -> Void

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
                Text(statusText)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if item.phase.isActive {
                if isCancellable {
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                }
            } else {
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

/// Window → Downloads, to reopen the window after closing it.
struct DownloadsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Downloads") { openWindow(id: DownloadsWindow.id) }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
