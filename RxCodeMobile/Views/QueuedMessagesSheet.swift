import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Queued Messages Sheet

struct QueuedMessagesSheet: View {
    let messages: [QueuedUserMessage]
    let sendMode: QueuedSendMode
    let onRemove: (QueuedUserMessage) -> Void
    let onAction: (QueuedUserMessage, String?, Bool) async throws -> Void
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
                                sendActions(queued)
                            }
                            .onTapGesture {
                                draft = queued.text
                                editing = queued
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                sendActions(queued)
                                .tint(.orange)

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

    @ViewBuilder
    private func sendActions(_ message: QueuedUserMessage) -> some View {
        if sendMode == .steer || sendMode == .steerOrInterrupt {
            Button("Steer Now", systemImage: "arrow.turn.up.right") {
                perform(message, text: nil)
            }
            .disabled(busy)
        }
        if sendMode == .interrupt || sendMode == .steerOrInterrupt {
            Button("Interrupt and Send", systemImage: "paperplane.fill") {
                perform(message, text: nil, interrupt: true)
            }
            .disabled(busy)
        }
    }

    private func perform(_ message: QueuedUserMessage, text: String?, interrupt: Bool = false) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await onAction(message, text, interrupt)
                editing = nil
                if text != nil {
                    status = "Update requested."
                } else if interrupt {
                    status = "Interrupt requested. The instruction stays queued until the response ends."
                } else {
                    status = "Steer requested. If unavailable, the instruction stays queued."
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                editing = nil
                status = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
