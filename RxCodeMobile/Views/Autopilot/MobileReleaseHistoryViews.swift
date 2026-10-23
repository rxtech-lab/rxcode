import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Recent releases

private struct MobileReleaseDispatchAppearance {
    let item: ReleaseDispatchHistoryItem
    var title: LocalizedStringKey {
        switch item.status {
        case "pending": "Pending"
        case "triggered": "Started"
        case "completed": "Completed"
        case "failed": "Failed"
        default: LocalizedStringKey(item.status.capitalized)
        }
    }
    var icon: String {
        switch item.status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        default: "clock.fill"
        }
    }
    var color: Color {
        switch item.status {
        case "completed": .green
        case "failed": .red
        default: .orange
        }
    }
}

struct MobileReleaseDispatchRow: View {
    let item: ReleaseDispatchHistoryItem
    let workflowName: String?

    var body: some View {
        let look = MobileReleaseDispatchAppearance(item: item)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: look.icon).foregroundStyle(look.color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(workflowName ?? String(localized: "Release")).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Text(look.title)
                    Text("· \(item.branch)").font(.caption.monospaced())
                    if let date = item.triggeredDate { Text("· \(date, format: .relative(presentation: .named))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MobileReleaseDispatchDetailView: View {
    @Environment(\.openURL) private var openURL
    let item: ReleaseDispatchHistoryItem
    let workflowName: String?

    var body: some View {
        let look = MobileReleaseDispatchAppearance(item: item)
        List {
            Section {
                if let workflowName { LabeledContent("Workflow", value: workflowName) }
                LabeledContent("Status") { Label(look.title, systemImage: look.icon).foregroundStyle(look.color) }
                LabeledContent("Branch") { Text(item.branch).font(.body.monospaced()) }
                if let date = item.triggeredDate {
                    LabeledContent("Started", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let date = item.completedAt?.date {
                    LabeledContent("Finished", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let inputs = item.inputValues, !inputs.isEmpty {
                Section("Inputs") {
                    ForEach(inputs.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: inputs[key]?.description ?? "")
                    }
                }
            }
            if let message = item.errorMessage, !message.isEmpty {
                Section("Error") { Text(message).font(.callout).textSelection(.enabled) }
            }
        }
        .navigationTitle(workflowName ?? String(localized: "Release"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let raw = item.workflowRunUrl, let url = URL(string: raw) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("View Run", systemImage: "safari") { MobileHaptics.buttonTap(); openURL(url) }
                }
            }
        }
    }
}

// MARK: - RELEASE_TOKEN

struct MobileReleaseTokenSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repo: ReleaseRepo
    let onInstalled: (String) -> Void

    @State private var token = ""
    @State private var installing = false
    @State private var errorMessage: String?

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("ghp_… or github_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                } header: {
                    Text("Personal Access Token")
                } footer: {
                    Text("Installed as the RELEASE_TOKEN GitHub Actions secret in \(repo.repositoryFullName) so the release workflow can publish. The token is encrypted on the server and never shown again.")
                }
            }
            .disabled(installing)
            .navigationTitle("RELEASE_TOKEN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { MobileHaptics.buttonTap(); dismiss() }.disabled(installing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") { Task { await install() } }.disabled(installing || trimmed.isEmpty)
                }
            }
            .alert("Could Not Install Token", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .mobileAutopilotLoadingDialog(installing, title: "Installing RELEASE_TOKEN…")
        }
        .interactiveDismissDisabled(installing || !trimmed.isEmpty)
    }

    private func install() async {
        installing = true
        MobileHaptics.buttonTap()
        defer { installing = false }
        do {
            let result = try await state.installReleaseToken(repoId: repo.id, value: trimmed)
            MobileHaptics.connected()
            onInstalled(result.secretName)
            dismiss()
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }
}
