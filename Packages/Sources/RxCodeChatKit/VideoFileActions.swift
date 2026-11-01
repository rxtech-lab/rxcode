#if os(macOS)
import AppKit
import SwiftUI
import RxCodeCore

/// Shared file actions for generated clips and footage in the studio.
struct VideoFileActions: ViewModifier {
    static let fileDeleted = Notification.Name("RxCode.videoFileDeleted")

    @Environment(WindowState.self) private var windowState
    let path: String?
    var beforePlayback: () -> Void = {}
    var select: (() -> Void)?
    /// Offers Continue from This Video: its last frame starts the next clip.
    var continues = false
    @State private var pendingDeletion: String?
    @State private var isDeleting = false
    @State private var status: String?
    @State private var error: String?
    @State private var failedToContinue = false

    private var available: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func body(content: Content) -> some View {
        content
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in
                switch value {
                case .first: play()
                case .second: select?()
                }
            })
            .contextMenu {
                if continues {
                    Button("Continue from This Video", systemImage: "arrow.triangle.branch", action: continueFromLastFrame)
                        .disabled(!available || isDeleting)
                    Divider()
                }
                Button("Show in Finder", systemImage: "folder") {
                    guard let path else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .disabled(!available || isDeleting)
                Button("Play", systemImage: "play.fill", action: play)
                    .disabled(!available || isDeleting)
                Divider()
                Button("Delete from Disk…", systemImage: "trash", role: .destructive) {
                    pendingDeletion = path
                }
                .disabled(!available || isDeleting)
            }
            .alert("Delete Video from Disk?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { target in
                Button("Delete", role: .destructive) { delete(target) }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { target in
                Text("\((target as NSString).lastPathComponent) will be permanently deleted. This cannot be undone. The prompt will remain in this thread.")
            }
            .alert(failedToContinue ? "Couldn't Continue from Video" : "Couldn't Delete Video", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .overlay {
                if let status {
                    HStack {
                        if isDeleting { ProgressView().controlSize(.small) }
                        Text(status).font(.callout)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                }
            }
            .task(id: status) {
                guard status != nil, !isDeleting else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                status = nil
            }
    }

    private func play() {
        guard available, !isDeleting, let path else { return }
        beforePlayback()
        windowState.playingVideo = PreviewFile(path: path, name: (path as NSString).lastPathComponent)
    }

    private func continueFromLastFrame() {
        guard available, let path else { return }
        select?()
        status = String(localized: "Preparing last frame…", bundle: .module)
        Task {
            do {
                try await StudioContinuation.attachLastFrame(ofVideoAt: path, to: windowState)
                status = String(localized: "Last frame added to the prompt", bundle: .module)
            } catch {
                status = nil
                failedToContinue = true
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ target: String) {
        pendingDeletion = nil
        isDeleting = true
        status = "Deleting…"
        beforePlayback()
        if windowState.playingVideo?.path == target { windowState.playingVideo = nil }
        Task {
            do {
                try await Task.detached {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: target))
                }.value
                isDeleting = false
                status = "Deleted from disk"
                NotificationCenter.default.post(name: Self.fileDeleted, object: target)
            } catch {
                isDeleting = false
                failedToContinue = false
                status = nil
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
