import RxCodeCore
import SwiftUI

/// "Create Release" dispatch dialog. Shows the current version, a branch picker,
/// and the selected release workflow's `workflow_dispatch` inputs (parsed from
/// its YAML), then triggers the workflow. Mirrors the webapp's
/// workflow-dispatch dialog.
struct ReleaseCreateSheet: View {
    /// UUID or `owner/repo` — both resolve server-side.
    let repoId: String
    let repoFullName: String
    /// Latest released tag, shown as the current version.
    let currentVersion: String?
    /// Branch names to offer (e.g. the project's local git branches). When
    /// empty and `projectPath` is set, the project's local branches are loaded;
    /// otherwise the branch becomes a free-text field.
    var branches: [String] = []
    /// Local checkout path used to source branches when `branches` is empty.
    var projectPath: String? = nil
    var defaultBranch: String = "main"

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var workflows: [ReleaseWorkflow] = []
    @State private var selectedWorkflowId: String?
    @State private var branch: String = ""
    @State private var branchOptions: [String] = []
    /// Input values keyed by input name (booleans stored as "true"/"false").
    @State private var inputValues: [String: String] = [:]

    @State private var isLoading = false
    @State private var isDispatching = false
    @State private var loadError: String?
    @State private var dispatchError: String?
    @State private var dispatchedURL: URL?

    private var dispatchableWorkflows: [ReleaseWorkflow] {
        workflows.filter { $0.hasWorkflowDispatch }
    }

    private var selectedWorkflow: ReleaseWorkflow? {
        workflows.first(where: { $0.id == selectedWorkflowId })
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red)
                } else if dispatchableWorkflows.isEmpty {
                    Text("No dispatchable release workflow found for \(repoFullName). Add a `workflow_dispatch` release workflow and rescan, then try again.")
                        .foregroundStyle(.secondary)
                } else {
                    detailsSection
                    if let workflow = selectedWorkflow, let inputs = workflow.inputs, !inputs.isEmpty {
                        inputsSection(inputs)
                    }
                    if let dispatchError {
                        Section { Text(dispatchError).foregroundStyle(.red).font(.callout) }
                    }
                    if let dispatchedURL {
                        Section {
                            Label("Release workflow triggered", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Link("View workflow run on GitHub", destination: dispatchedURL)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Create Release")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dispatchedURL == nil ? "Cancel" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await dispatch() }
                    } label: {
                        if isDispatching { ProgressView().controlSize(.small) } else { Text("Create Release") }
                    }
                    .disabled(isDispatching || selectedWorkflow == nil || resolvedBranch.isEmpty || dispatchedURL != nil)
                }
            }
        }
        .frame(width: 480, height: 480)
        .task { await load() }
    }

    private var resolvedBranch: String {
        branch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sections

    @ViewBuilder
    private var detailsSection: some View {
        Section("Release") {
            LabeledContent("Repository", value: repoFullName)
            LabeledContent("Current version", value: currentVersion ?? "—")

            if dispatchableWorkflows.count > 1 {
                Picker("Workflow", selection: $selectedWorkflowId) {
                    ForEach(dispatchableWorkflows) { wf in
                        Text(wf.displayName).tag(Optional(wf.id))
                    }
                }
            } else if let wf = dispatchableWorkflows.first {
                LabeledContent("Workflow", value: wf.displayName)
            }

            if branchOptions.isEmpty {
                TextField("Branch", text: $branch)
            } else {
                Picker("Branch", selection: $branch) {
                    ForEach(branchOptions, id: \.self) { Text($0).tag($0) }
                }
            }

            Text("The next version is computed by semantic-release from the commit history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func inputsSection(_ inputs: [ReleaseWorkflowInput]) -> some View {
        Section("Workflow inputs") {
            ForEach(inputs) { input in
                inputField(input)
            }
        }
    }

    @ViewBuilder
    private func inputField(_ input: ReleaseWorkflowInput) -> some View {
        let label = input.name + (input.required ? " *" : "")
        switch input.type {
        case "boolean":
            Toggle(label, isOn: boolBinding(for: input.name))
        case "choice":
            Picker(label, selection: stringBinding(for: input.name)) {
                ForEach(input.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                TextField(label, text: stringBinding(for: input.name))
                if let desc = input.description, !desc.isEmpty {
                    Text(desc).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stringBinding(for name: String) -> Binding<String> {
        Binding(
            get: { inputValues[name] ?? "" },
            set: { inputValues[name] = $0 }
        )
    }

    private func boolBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { inputValues[name] == "true" },
            set: { inputValues[name] = $0 ? "true" : "false" }
        )
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            // Source branches: explicit list wins, else the project's local git.
            if !branches.isEmpty {
                branchOptions = branches
            } else if let projectPath {
                branchOptions = await GitHelper.listLocalBranches(at: projectPath)
            }
            workflows = try await appState.release.listWorkflows(repoId: repoId)
            // Default to the selected dispatchable workflow, else the first.
            let preferred = workflows.first(where: { $0.isSelected && $0.hasWorkflowDispatch })
                ?? dispatchableWorkflows.first
            selectedWorkflowId = preferred?.id
            if branch.isEmpty {
                branch = branchOptions.first ?? defaultBranch
            }
            seedDefaults(for: preferred)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Prefill `inputValues` from each input's default so the form starts in a
    /// valid state.
    private func seedDefaults(for workflow: ReleaseWorkflow?) {
        guard let inputs = workflow?.inputs else { return }
        for input in inputs where inputValues[input.name] == nil {
            if input.type == "boolean" {
                inputValues[input.name] = (input.defaultBool ?? false) ? "true" : "false"
            } else {
                inputValues[input.name] = input.defaultString ?? (input.options?.first ?? "")
            }
        }
    }

    private func dispatch() async {
        guard let workflow = selectedWorkflow else { return }
        isDispatching = true
        dispatchError = nil
        defer { isDispatching = false }
        do {
            let result = try await appState.release.dispatch(
                repoId: repoId,
                body: ReleaseDispatchRequest(
                    workflowId: workflow.id,
                    branch: resolvedBranch,
                    inputs: inputValues
                )
            )
            if let urlString = result.workflowRunUrl, let url = URL(string: urlString) {
                dispatchedURL = url
            } else if result.success == false {
                dispatchError = result.error ?? "Failed to trigger the release workflow."
            } else {
                // Triggered but no URL returned — still a success.
                dispatchedURL = URL(string: "https://github.com/\(repoFullName)/actions")
            }
        } catch {
            dispatchError = error.localizedDescription
        }
    }
}
