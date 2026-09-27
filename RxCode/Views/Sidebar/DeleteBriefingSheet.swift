import SwiftUI
import RxCodeCore

/// Dedicated confirmation for deleting a generated or document briefing.
struct DeleteBriefingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: LocalizedStringKey
    let delete: () async throws -> Void

    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("Delete Briefing")
                    .font(.title2.weight(.semibold))
            }

            Text(message)
                .foregroundStyle(ClaudeTheme.textSecondary)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Briefing", role: .destructive) {
                    isDeleting = true
                    Task {
                        do {
                            try await delete()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isDeleting = false
                        }
                    }
                }
                .disabled(isDeleting)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(ClaudeTheme.background)
    }
}
