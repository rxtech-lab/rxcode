import RxCodeCore
import RxCodeSync
import SwiftUI

/// Registers the current repository using the existing native feature services.
struct FlowcyProjectFeatureSetup: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let project: CloudProject
    let section: FlowcyProjectSection
    let onSave: () async -> Void
    @State private var frequency: CIScanFrequency = .weekly
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    Text(project.repositoryFullName ?? project.title)
                }
                Section {
                    if section == .updates {
                        Picker("Scan Frequency", selection: $frequency) {
                            ForEach(CIScanFrequency.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        Text("Watch this repository for dependency and CI updates. Automated scans may create pull requests.")
                    } else {
                        Text("Enable native release management for this repository. You can review workflows and trigger releases from your device.")
                    }
                }
            }
            .disabled(saving)
            .navigationTitle("Set Up \(section.rawValue)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { MobileHaptics.buttonTap(); dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enable") { Task { await save() } }.disabled(saving)
                }
            }
            .overlay {
                if saving {
                    ProgressView("Enabling feature…").padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Could Not Enable Feature", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }.interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        MobileHaptics.buttonTap()
        defer { saving = false }
        do {
            guard let name = project.repositoryFullName else {
                throw FlowcyError.message("This feature requires a GitHub repository.")
            }
            // Resolve server-owned installation and repository IDs, including paginated results.
            var cursor: String?
            var visited = Set<String>()
            var repository: SecretsManagedRepo?
            repeat {
                let page = try await state.listAutopilotRepos(search: name, cursor: cursor)
                repository = page.items.first { project.matchesRepository($0.fullName) }
                cursor = page.pagination.hasMore ? page.pagination.nextCursor : nil
                if let cursor, !visited.insert(cursor).inserted { break }
            } while repository == nil && cursor != nil
            guard let repo = repository else {
                throw FlowcyError.message("This repository is not accessible to your account. Check its GitHub App access and try again.")
            }
            switch section {
            case .updates:
                try await state.addWatchedRepo(AddWatchedRepoBody(
                    installationId: repo.installationId, repositoryId: repo.id,
                    repositoryFullName: repo.fullName, scanFrequency: frequency
                ))
            case .releases:
                try await state.addReleaseRepo(AddReleaseRepoBody(
                    installationId: repo.installationId, repositoryId: repo.id,
                    repositoryFullName: repo.fullName
                ))
            default:
                throw FlowcyError.message("This feature does not require repository registration.")
            }
            await onSave()
            MobileHaptics.connected()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}
