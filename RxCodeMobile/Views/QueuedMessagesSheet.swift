import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Queued Messages Sheet

struct QueuedMessagesSheet: View {
    let messages: [QueuedUserMessage]
    let onRemove: (QueuedUserMessage) -> Void
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
                                Text(queued.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onRemove(queued)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Queued Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .mobileSheetPresentation([.medium, .large])
    }
}
