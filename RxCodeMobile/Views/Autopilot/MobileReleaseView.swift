import RxCodeCore
import RxCodeSync
import SwiftUI

/// Release management: registered release repositories, their scanned
/// workflows, the RELEASE_TOKEN secret, and triggering releases.
struct MobileReleaseView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var repos: [ReleaseRepo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var pendingDelete: ReleaseRepo?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(repos) { repo in
                NavigationLink {
                    MobileReleaseRepoDetailView(repo: repo)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.repositoryFullName)
                        if let tag = repo.latestReleaseTag {
                            Text("Latest: \(tag)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingDelete = repo }
                }
            }
            if repos.isEmpty, !isLoading {
                Text("No release repositories. Tap + to add one.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            MobileAutopilotRepoPicker(
                title: "Add Release Repository",
                existingRepoFullNames: Set(repos.map { $0.repositoryFullName.lowercased() })
            ) { repo in
                await add(repo)
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .alert(
            "Remove repository?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let repo = pendingDelete { Task { await delete(repo) } }
                pendingDelete = nil
            }
        }
        .mobileAutopilotLoadingOverlay(isLoading && repos.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            repos = try await state.listReleaseRepos().items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ repo: SecretsManagedRepo) async {
        do {
            try await state.addReleaseRepo(AddReleaseRepoBody(
                installationId: repo.installationId,
                repositoryId: repo.id,
                repositoryFullName: repo.fullName
            ))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ repo: ReleaseRepo) async {
        do {
            try await state.deleteReleaseRepo(id: repo.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileReleaseRepoDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    let repo: ReleaseRepo

    @State private var workflows: [MobileReleaseWorkflow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var tokenValue = ""
    @State private var isInstallingToken = false
    @State private var dispatchWorkflow: MobileReleaseWorkflow?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
            }

            Section("Workflows") {
                if workflows.isEmpty, !isLoading {
                    Text("No workflows scanned yet.").foregroundStyle(.secondary)
                }
                ForEach(workflows) { workflow in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.displayName)
                            Text(workflow.workflowPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if workflow.isSelected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        if workflow.hasWorkflowDispatch {
                            Button("Release") { dispatchWorkflow = workflow }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                SecureField("ghp_… or github_pat_…", text: $tokenValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await installToken() }
                } label: {
                    if isInstallingToken {
                        HStack { ProgressView(); Text("Installing…") }
                    } else {
                        Label("Install RELEASE_TOKEN", systemImage: "key.horizontal")
                    }
                }
                .disabled(isInstallingToken || tokenValue.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("RELEASE_TOKEN")
            } footer: {
                Text("Installed as the repo's GitHub Actions secret so the release workflow can publish.")
            }
        }
        .navigationTitle(repo.repositoryFullName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $dispatchWorkflow) { workflow in
            MobileReleaseDispatchView(repo: repo, workflow: workflow) { message in
                statusMessage = message
                await reload()
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .mobileAutopilotLoadingOverlay(isLoading && workflows.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            workflows = try await state.listReleaseWorkflows(repoId: repo.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installToken() async {
        isInstallingToken = true
        statusMessage = nil
        errorMessage = nil
        defer { isInstallingToken = false }
        do {
            let result = try await state.installReleaseToken(repoId: repo.id, value: tokenValue.trimmingCharacters(in: .whitespacesAndNewlines))
            statusMessage = "Installed \(result.secretName)."
            tokenValue = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Fills out a release workflow's `workflow_dispatch` inputs and triggers it.
struct MobileReleaseDispatchView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repo: ReleaseRepo
    let workflow: MobileReleaseWorkflow
    let onDispatched: (String) async -> Void

    @State private var branch: String
    @State private var inputValues: [String: String] = [:]
    @State private var isDispatching = false
    @State private var errorMessage: String?

    init(repo: ReleaseRepo, workflow: MobileReleaseWorkflow, onDispatched: @escaping (String) async -> Void) {
        self.repo = repo
        self.workflow = workflow
        self.onDispatched = onDispatched
        _branch = State(initialValue: repo.repositoryFullName.isEmpty ? "main" : "main")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Branch") {
                    TextField("main", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let inputs = workflow.inputs, !inputs.isEmpty {
                    Section("Inputs") {
                        ForEach(inputs) { input in
                            inputRow(input)
                        }
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Create Release")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Dispatch") { Task { await dispatch() } }
                        .disabled(isDispatching || branch.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: seedDefaults)
        }
    }

    @ViewBuilder
    private func inputRow(_ input: MobileReleaseWorkflowInput) -> some View {
        let binding = Binding(
            get: { inputValues[input.name] ?? input.defaultString ?? "" },
            set: { inputValues[input.name] = $0 }
        )
        if input.type == "boolean" {
            Toggle(input.name, isOn: Binding(
                get: { (inputValues[input.name] ?? (input.defaultBool == true ? "true" : "false")) == "true" },
                set: { inputValues[input.name] = $0 ? "true" : "false" }
            ))
        } else if input.type == "choice", let options = input.options {
            Picker(input.name, selection: binding) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(input.name).font(.caption).foregroundStyle(.secondary)
                TextField(input.description ?? input.name, text: binding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private func seedDefaults() {
        for input in workflow.inputs ?? [] where inputValues[input.name] == nil {
            if let value = input.defaultString { inputValues[input.name] = value }
        }
    }

    private func dispatch() async {
        isDispatching = true
        errorMessage = nil
        defer { isDispatching = false }
        do {
            let result = try await state.dispatchRelease(
                repoId: repo.id,
                request: ReleaseDispatchRequest(
                    workflowId: workflow.id,
                    branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
                    inputs: inputValues
                )
            )
            if result.success == false, let error = result.error {
                errorMessage = error
                return
            }
            await onDispatched("Release dispatched.")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
