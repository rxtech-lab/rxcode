import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Rename Thread Sheet

/// Compact modal that captures a new thread title. Commits the trimmed value
/// via `onSubmit` and dismisses; an empty title is treated as a no-op.
struct RenameThreadSheet: View {
    let currentTitle: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(currentTitle: String, onSubmit: @escaping (String) -> Void) {
        self.currentTitle = currentTitle
        self.onSubmit = onSubmit
        _text = State(initialValue: currentTitle)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != currentTitle
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thread name") {
                    TextField("Thread name", text: $text)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                }
            }
            .navigationTitle("Rename Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isFocused = true
                }
            }
        }
        .mobileSheetPresentation([.medium])
    }

    private func commit() {
        guard canSave else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
