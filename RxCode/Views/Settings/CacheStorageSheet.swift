import RxCodeCore
import SwiftUI

private struct ShowCacheStorageKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var showCacheStorage: (() -> Void)? {
        get { self[ShowCacheStorageKey.self] }
        set { self[ShowCacheStorageKey.self] = newValue }
    }
}

struct CacheStoragePresenter: ViewModifier {
    let workspaceManager: WorkspaceManager
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.showCacheStorage) { isPresented = true }
            .sheet(isPresented: $isPresented) {
                CacheStorageSheet(workspaceManager: workspaceManager)
            }
    }
}

struct CacheStorageSheet: View {
    let workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var storage: StorageBreakdown?
    @State private var isClearing = false
    @State private var showConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Storage and Cache")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Total occupied space")
                    .font(.headline)
                Text(storage.map { formatBytes($0.totalBytes) } ?? "Calculating…")
                    .font(.title3.monospacedDigit())
                Text("Includes RxCode's Application Support and Caches data across all workspaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let storage {
                VStack(alignment: .leading, spacing: 10) {
                    storageRow("Stored data retained after clearing", bytes: storage.retainedBytes)
                        .fontWeight(.semibold)
                    storageRow("Attachments", bytes: storage.attachments)
                    storageRow("Chats and session files", bytes: storage.sessions)
                    storageRow("Thread database", bytes: storage.threadDatabase)
                    storageRow("Workspaces and task boards", bytes: storage.workspaces)
                    storageRow("Diagnostics", bytes: storage.diagnostics)
                    storageRow("Other app data", bytes: storage.other)
                    Divider()
                    storageRow("Clearable files and briefings", bytes: storage.clearableFiles)
                }
            }

            Text("Clear Cached Data removes briefings, summaries, search embeddings, icons, and compiled caches. Attachments and chats remain. The thread database may keep allocated space after its cached records are deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(role: .destructive) { showConfirmation = true } label: {
                    if isClearing { ProgressView().controlSize(.small) }
                    else { Text("Clear Cached Data…") }
                }
                .disabled(isClearing)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await refreshSize() }
        .confirmationDialog("Clear all cached data?", isPresented: $showConfirmation) {
            Button("Clear Cached Data", role: .destructive) {
                Task { await clear() }
            }
        } message: {
            Text("Briefings and other cached data will be removed from every workspace.")
        }
    }

    private func storageRow(_ title: String, bytes: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatBytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshSize() async {
        storage = await CacheStorageService.shared.breakdown()
    }

    private func clear() async {
        isClearing = true
        errorMessage = nil
        do {
            try await workspaceManager.clearCachedData()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshSize()
        isClearing = false
    }
}
