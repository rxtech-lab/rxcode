import RxCodeCore
import SwiftUI

/// Adds a trusted notification email. Autopilot emails the address a
/// verification link; notifications can go there once its owner confirms.
struct AddTrustedEmailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onAdded: (TrustedEmail) -> Void

    @State private var email = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksValid: Bool {
        let parts = trimmed.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !trimmed.contains(" ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email address", text: $email, prompt: Text(verbatim: "name@example.com"))
                        .textContentType(.emailAddress)
                        .onSubmit { if looksValid { Task { await submit() } } }
                } footer: {
                    Text("We'll email a verification link to this address. It expires after 24 hours.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Trusted Email")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Send Link") { Task { await submit() } }
                            .disabled(!looksValid)
                    }
                }
            }
        }
        .frame(width: 420, height: 240)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let added = try await appState.autopilotNotifications.addTrustedEmail(trimmed)
            onAdded(added)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
