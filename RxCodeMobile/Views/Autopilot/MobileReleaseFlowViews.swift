import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Workflow file

/// The workflow YAML with syntax highlighting and line numbers.
struct MobileWorkflowFileView: View {
    let repoId: String
    let workflow: MobileReleaseWorkflow
    let onRelease: (() -> Void)?
    let onToggleRelease: () async -> Void

    @State private var lineDisplay: DiffView.LineDisplay = .scroll
    @State private var toast: String?

    var body: some View {
        Group {
            if let content = workflow.content, !content.isEmpty {
                DiffView(lines: Self.lines(content), showsDiffMarkers: false, display: lineDisplay, language: "yaml")
            } else {
                ContentUnavailableView("File Unavailable", systemImage: "doc.text",
                                       description: Text("Update Flowcy on your Mac to view workflow files, or rescan workflows."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(workflow.workflowPath.split(separator: "/").last.map(String.init) ?? workflow.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onRelease {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Release", systemImage: "paperplane") { onRelease() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(lineDisplay == .wrap ? "Don't Wrap Lines" : "Wrap Lines",
                           systemImage: lineDisplay == .wrap ? "arrow.left.and.right.text.vertical" : "text.word.spacing") {
                        MobileHaptics.buttonTap()
                        lineDisplay = lineDisplay == .wrap ? .scroll : .wrap
                    }
                    if let content = workflow.content {
                        Button("Copy File", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = content
                            MobileHaptics.connected()
                            toast = String(localized: "Copied \(workflow.workflowPath).")
                        }
                        ShareLink(item: content, preview: SharePreview(workflow.workflowPath))
                    }
                    Section {
                        Button(workflow.isSelected ? "Unmark as Release Workflow" : "Mark as Release Workflow",
                               systemImage: workflow.isSelected ? "tag.slash" : "tag") {
                            Task { await onToggleRelease() }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Text(workflow.workflowPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if workflow.isSelected { MobileReleaseBadge(title: "Release", color: .accentColor) }
                if workflow.hasWorkflowDispatch { MobileReleaseBadge(title: "Manual Trigger", color: .green) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .mobileStatusToast($toast)
    }

    static func lines(_ text: String) -> [DiffLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return (lines.isEmpty ? [""] : lines).enumerated().map { index, line in
            DiffLine(text: line, kind: .context, oldLineNumber: nil, newLineNumber: index + 1)
        }
    }
}

// MARK: - Release flow

/// First step of a release: choose which workflow to run.
struct MobileReleaseWorkflowPicker: View {
    @Environment(\.dismiss) private var dismiss
    let repo: ReleaseRepo
    let workflows: [MobileReleaseWorkflow]
    let onDispatched: (String) async -> Void

    var body: some View {
        List {
            Section {
                ForEach(workflows) { workflow in
                    NavigationLink {
                        MobileReleaseDispatchView(repo: repo, workflow: workflow) { message in
                            await onDispatched(message)
                            dismiss()
                        }
                    } label: {
                        MobileReleaseWorkflowRow(workflow: workflow)
                    }
                }
            } footer: {
                Text("Only workflows with a workflow_dispatch trigger can be started from Flowcy.")
            }
        }
        .overlay {
            if workflows.isEmpty {
                ContentUnavailableView("No Release Workflows", systemImage: "paperplane",
                                       description: Text("Add a workflow_dispatch trigger to a workflow, then rescan workflows."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Choose Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { MobileHaptics.buttonTap(); dismiss() }
            }
        }
    }
}

/// Second step: branch and `workflow_dispatch` inputs, then confirm.
struct MobileReleaseDispatchView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repo: ReleaseRepo
    let workflow: MobileReleaseWorkflow
    /// True when this is the sheet's first screen, so it owns the Cancel button.
    var isRoot = false
    let onDispatched: (String) async -> Void

    @State private var branch = ""
    @State private var serverBranches: [ReleaseBranch]?
    @State private var inputValues: [String: String] = [:]
    @State private var isDispatching = false
    @State private var confirmDispatch = false
    @State private var errorMessage: String?
    @State private var missingInputs: Set<String> = []

    /// Branches from GitHub, falling back to the Mac's synced branch list.
    private var branchOptions: [String] {
        if let serverBranches, !serverBranches.isEmpty { return serverBranches.map(\.name) }
        guard let project = state.projects.first(where: {
            $0.gitHubRepo?.lowercased() == repo.repositoryFullName.lowercased()
        }) else { return [] }
        return state.availableBranchesByProject[project.id] ?? []
    }

    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("Workflow") {
                LabeledContent("Name", value: workflow.displayName)
                LabeledContent("File") {
                    Text(workflow.workflowPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                if workflow.content != nil {
                    NavigationLink("View Workflow File") {
                        MobileWorkflowFileView(repoId: repo.id, workflow: workflow, onRelease: nil, onToggleRelease: {})
                    }
                }
            }
            Section {
                if branchOptions.isEmpty {
                    TextField("main", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Picker("Branch", selection: $branch) {
                        ForEach(branchOptions, id: \.self) { name in
                            HStack {
                                Text(name)
                                if serverBranches?.first(where: { $0.name == name })?.protected == true {
                                    Image(systemName: "lock.fill")
                                }
                            }
                            .tag(name)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            } header: {
                Text("Branch")
            } footer: {
                Text("The workflow runs on the latest commit of this branch.")
            }
            if let inputs = workflow.inputs, !inputs.isEmpty {
                ForEach(inputs) { input in
                    Section {
                        inputRow(input)
                    } header: {
                        Text(input.required ? "\(input.name) *" : input.name)
                    } footer: {
                        if missingInputs.contains(input.name) {
                            Text("This input is required.").foregroundStyle(.red)
                        } else if let description = input.description, !description.isEmpty {
                            Text(description)
                        }
                    }
                }
            }
        }
        .disabled(isDispatching)
        .navigationTitle("Create Release")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { MobileHaptics.buttonTap(); dismiss() }.disabled(isDispatching)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Release") { review() }
                    .disabled(isDispatching || trimmedBranch.isEmpty)
            }
        }
        .confirmationDialog("Start \(workflow.displayName)?", isPresented: $confirmDispatch, titleVisibility: .visible) {
            Button("Start Release") { Task { await dispatch() } }
        } message: {
            Text("Runs on \(trimmedBranch) in \(repo.repositoryFullName).")
        }
        .alert("Release Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .mobileAutopilotLoadingDialog(isDispatching, title: "Starting release…")
        .interactiveDismissDisabled(isDispatching)
        .onAppear(perform: seedInputs)
        .task { await loadBranches() }
    }

    @ViewBuilder
    private func inputRow(_ input: MobileReleaseWorkflowInput) -> some View {
        let binding = Binding(
            get: { inputValues[input.name] ?? "" },
            set: { inputValues[input.name] = $0; missingInputs.remove(input.name) }
        )
        if input.type == "boolean" {
            Toggle(input.name, isOn: Binding(
                get: { inputValues[input.name] == "true" },
                set: { inputValues[input.name] = $0 ? "true" : "false"; MobileHaptics.buttonTap() }
            ))
        } else if input.type == "choice", let options = input.options, !options.isEmpty {
            Picker(input.name, selection: binding) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
        } else {
            TextField(input.defaultString ?? input.name, text: binding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func seedInputs() {
        for input in workflow.inputs ?? [] where inputValues[input.name] == nil {
            if input.type == "boolean" {
                inputValues[input.name] = input.defaultBool == true ? "true" : "false"
            } else if input.type == "choice", let options = input.options, !options.isEmpty {
                inputValues[input.name] = input.defaultString.flatMap { options.contains($0) ? $0 : nil } ?? options[0]
            } else if let value = input.defaultString {
                inputValues[input.name] = value
            }
        }
        if branch.isEmpty { pickDefaultBranch() }
    }

    private func loadBranches() async {
        guard serverBranches == nil else { return }
        serverBranches = (try? await state.listReleaseBranches(repoId: repo.id)) ?? []
        if !branchOptions.contains(branch) { pickDefaultBranch() }
    }

    /// Prefer the Mac's current branch, then main/master, then the first branch.
    private func pickDefaultBranch() {
        let options = branchOptions
        guard !options.isEmpty else {
            if branch.isEmpty { branch = "main" }
            return
        }
        let project = state.projects.first { $0.gitHubRepo?.lowercased() == repo.repositoryFullName.lowercased() }
        let current = project.flatMap { state.projectBranches[$0.id] }
        branch = [current, "main", "master"].compactMap { $0 }.first(where: options.contains) ?? options[0]
    }

    private func review() {
        MobileHaptics.buttonTap()
        let missing = (workflow.inputs ?? []).filter { input in
            input.required && input.type != "boolean"
                && (inputValues[input.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        missingInputs = Set(missing.map(\.name))
        guard missing.isEmpty else {
            MobileHaptics.connectionError()
            return
        }
        confirmDispatch = true
    }

    private func dispatch() async {
        isDispatching = true
        defer { isDispatching = false }
        do {
            let result = try await state.dispatchRelease(
                repoId: repo.id,
                request: ReleaseDispatchRequest(workflowId: workflow.id, branch: trimmedBranch, inputs: inputValues)
            )
            if result.success == false {
                throw FlowcyError.message(result.error ?? String(localized: "The release workflow could not be started."))
            }
            await onDispatched(String(localized: "Release started on \(trimmedBranch)."))
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }
}
