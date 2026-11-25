import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct PullRequestDraftModelPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let sections = appState.pullRequestModelSections()
        let models = sections.flatMap(\.models)
        Picker("Drafting Model", selection: Binding(
            get: { models.first { $0.key == appState.pullRequestModelKey }?.key ?? "" },
            set: { key in appState.rememberPullRequestModel(models.first { $0.key == key }) }
        )) {
            Text("Settings Default (\(appState.summarizationProvider.displayNameText))")
                .tag("")
            ForEach(sections, id: \.id) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { model in
                        Text(model.displayName).tag(model.key)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .menuOrder(.fixed)
        .accessibilityIdentifier("git-pr-model-picker")
    }
}

/// Drafts, reviews, and opens a pull request for a pushed branch.
struct GitCreatePullRequestSheet: View {
    private enum BodyMode: Hashable { case write, preview }

    let store: GitWorkflowStore
    let target: GitPullRequestTarget

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var title = ""
    @State private var prBody = ""
    @State private var bodyMode: BodyMode = .write
    @State private var draftingModelName: String?
    @State private var draftTask: Task<Void, Never>?
    @State private var creating = false
    @State private var error: String?

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftingModelName == nil && !creating
    }

    private var operation: LocalizedStringResource? {
        if creating { return "Creating pull request…" }
        if let draftingModelName { return "Drafting with \(draftingModelName)…" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Repository") { Text(verbatim: target.repository) }
                    LabeledContent("Merge") {
                        HStack(spacing: 4) {
                            Text(verbatim: target.branch)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            if let base = target.base {
                                Text(verbatim: base)
                            } else {
                                Text("Default branch")
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }

                Section {
                    PullRequestDraftModelPicker()
                    Button {
                        draft(with: appState.rememberedPullRequestModel)
                    } label: {
                        Label("Generate Draft", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("git-pr-generate-draft")
                }

                Section("Title") {
                    TextField("Title", text: $title, prompt: Text("feat: describe the change"))
                        .labelsHidden()
                        .accessibilityIdentifier("git-pr-title")
                }

                Section {
                    Group {
                        switch bodyMode {
                        case .write:
                            TextEditor(text: $prBody)
                                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .accessibilityIdentifier("git-pr-body")
                        case .preview:
                            ScrollView {
                                if prBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Nothing to preview")
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    MarkdownContentView(text: prBody)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 260, maxHeight: .infinity)
                } header: {
                    HStack {
                        Text("Description")
                        Spacer()
                        Picker("Description", selection: $bodyMode) {
                            Text("Write").tag(BodyMode.write)
                            Text("Preview").tag(BodyMode.preview)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(draftingModelName != nil || creating)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Create Pull Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        draftTask?.cancel()
                        dismiss()
                    }
                    .disabled(creating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 680, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .overlay { GitOperationOverlay(operation: operation) }
        .interactiveDismissDisabled(creating)
        .alert("Couldn't Create Pull Request", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear { draftTask?.cancel() }
    }

    private func draft(with model: AgentModel?) {
        guard draftingModelName == nil, !creating else { return }
        draftingModelName = model?.displayName ?? appState.summarizationProvider.displayNameText
        let root = store.root
        draftTask = Task { @MainActor in
            defer { draftingModelName = nil }
            let draft = await appState.draftPullRequest(
                root: root,
                branch: target.branch,
                remote: target.remote,
                base: target.base,
                model: model
            )
            guard !Task.isCancelled else { return }
            title = draft.title
            prBody = draft.body
        }
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        let checkout = store.gitHubCheckout
        Task { @MainActor in
            defer { creating = false }
            do {
                let url = try await appState.openPullRequest(
                    repository: target.repository,
                    branch: target.branch,
                    base: target.base,
                    title: title,
                    body: prBody
                )
                if let checkout { store.setPullRequestPresence(.exists(url: url), for: checkout) }
                openURL(url)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A project or briefing action can publish the branch as part of creating its PR.
struct ProjectPullRequestSheet: View {
    let request: ProjectPullRequestRequest

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Repository", value: request.project.gitHubRepo ?? request.project.name)
                    if let branch = request.branch {
                        LabeledContent("Branch", value: branch)
                    } else {
                        LabeledContent("Branch") { Text("Current branch") }
                    }
                }
                Section {
                    PullRequestDraftModelPicker()
                } footer: {
                    Text("RxCode will push the branch, draft the title and description, and open the pull request.")
                }
            }
            .formStyle(.grouped)
            .disabled(creating)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Create Pull Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate and Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(creating)
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .overlay { GitOperationOverlay(operation: creating ? "Creating pull request…" : nil) }
        .interactiveDismissDisabled(creating)
        .alert("Couldn't Create Pull Request", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func create() {
        guard !creating else { return }
        let model = appState.rememberedPullRequestModel
        creating = true
        Task { @MainActor in
            defer { creating = false }
            do {
                let url: URL
                if let branch = request.branch {
                    url = try await appState.createPullRequestForBranch(project: request.project, branch: branch, model: model)
                } else {
                    url = try await appState.createPullRequestForCurrentBranch(project: request.project, model: model)
                }
                openURL(url)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
