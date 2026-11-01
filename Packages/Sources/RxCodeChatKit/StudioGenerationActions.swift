#if os(macOS)
import AppKit
import SwiftUI
import RxCodeCore

/// Actions belong to the generation under the pointer, not the selected thread.
struct StudioGenerationActions: ViewModifier {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge
    let take: GenerationTake
    /// Branching from this take, where the studio supports it.
    var continueFrom: (() -> Void)? = nil
    @State private var deletionSessionID: String?
    @State private var isDeleting = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .contextMenu {
                if let continueFrom {
                    Button("Continue from This Image", systemImage: "arrow.triangle.branch", action: continueFrom)
                        .disabled(take.phase != .ready)
                    Divider()
                }
                Button("Show in Finder", systemImage: "folder") {
                    guard let path = take.path else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .disabled(take.path.map { FileManager.default.fileExists(atPath: $0) } != true)
                Divider()
                Button("Delete Generation…", systemImage: "trash", role: .destructive) {
                    deletionSessionID = windowState.currentSessionId
                }
                .disabled(chatBridge.isStreaming || isDeleting || chatBridge.deleteGenerationHandler == nil)
            }
            .alert("Delete Generation?", isPresented: Binding(
                get: { deletionSessionID != nil },
                set: { if !$0 { deletionSessionID = nil } }
            ), presenting: deletionSessionID) { sessionID in
                Button("Delete", role: .destructive) { delete(sessionID: sessionID) }
                Button("Cancel", role: .cancel) { deletionSessionID = nil }
            } message: { _ in
                Text("This removes the prompt and its response from this thread. Generated files will remain on disk. This cannot be undone.")
            }
            .alert("Couldn't Delete Generation", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .overlay {
                if isDeleting {
                    ProgressView("Deleting…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
    }

    private func delete(sessionID: String) {
        deletionSessionID = nil
        guard let handler = chatBridge.deleteGenerationHandler else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do { try await handler(sessionID, take.id) }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
