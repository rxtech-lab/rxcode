import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Queued Messages Sheet

struct QueuedMessagesSheet: View {
    let messages: [QueuedUserMessage]
    let onRemove: (QueuedUserMessage) -> Void
    let onAction: (QueuedUserMessage, String?) async throws -> Void
    @State private var editing: QueuedUserMessage?
    @State private var draft = ""
    @State private var status: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "No Queued Messages",
                        systemImage: "tray",
                        description: Text("Messages you queue while a response is streaming appear here.")
                    )
                } else {
                    List {
                        ForEach(messages) { queued in
                            VStack(alignment: .leading, spacing: 0) {
                                MarkdownContentView(text: queued.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") {
                                    draft = queued.text
                                    editing = queued
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                Button("Steer Now", systemImage: "arrow.turn.up.right") {
                                    perform(queued, text: nil)
                                }
                                .disabled(busy)
                            }
                            .onTapGesture {
                                draft = queued.text
                                editing = queued
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button("Steer Now", systemImage: "arrow.turn.up.right") {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    perform(queued, text: nil)
                                }
                                .tint(.orange)
                                .disabled(busy)

                                Button("Edit", systemImage: "pencil") {
                                    draft = queued.text
                                    editing = queued
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                .tint(.blue)
                                .disabled(busy)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onRemove(queued)
                                    status = "Removal requested."
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Queued Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $editing) { message in
            NavigationStack {
                TextEditor(text: $draft)
                    .padding()
                    .navigationTitle("Edit Queued Message")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editing = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { perform(message, text: draft) }
                                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .overlay(alignment: .top) {
            if let status {
                Text(status).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding().onTapGesture { self.status = nil }
            }
        }
        .mobileSheetPresentation([.medium, .large])
    }

    private func perform(_ message: QueuedUserMessage, text: String?) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await onAction(message, text)
                editing = nil
                status = text == nil ? "Steer requested. If unavailable, the message stays queued." : "Update requested."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                editing = nil
                status = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
