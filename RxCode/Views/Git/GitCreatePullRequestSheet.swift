import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Model choices for drafting a PR title and body: the summarization settings
/// default, then every Claude Code, Codex, and enabled ACP model. Picking an
/// entry remembers it for the next draft and calls `onSelect`.
struct PullRequestDraftModelMenuContent: View {
    @Environment(AppState.self) private var appState
    let onSelect: (AgentModel?) -> Void

    var body: some View {
        let remembered = appState.rememberedPullRequestModel
        Toggle(isOn: Binding(
            get: { remembered == nil },
            set: { _ in select(nil) }
        )) {
            Text("Settings Default (\(appState.summarizationProvider.displayNameText))")
        }
        ForEach(appState.pullRequestModelSections(), id: \.id) { section in
            Section(section.title) {
                ForEach(section.models, id: \.key) { model in
                    Toggle(isOn: Binding(
                        get: { remembered?.key == model.key },
                        set: { _ in select(model) }
                    )) {
                        Text(model.displayName)
                    }
                }
            }
        }
    }

    private func select(_ model: AgentModel?) {
        appState.rememberPullRequestModel(model)
        onSelect(model)
    }
}

/// Reviews and opens a pull request for a pushed branch. An agent drafts the
/// title and body when the sheet opens; the "Draft with" menu redrafts with a
/// different model.
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        PullRequestDraftModelMenuContent { model in draft(with: model) }
                    } label: {
                        Label("Draft with Agent", systemImage: "sparkles")
                    } primaryAction: {
                        draft(with: appState.rememberedPullRequestModel)
                    }
                    .help("Draft the title and description with an agent")
                    .disabled(draftingModelName != nil || creating)
                    .accessibilityIdentifier("git-pr-draft-menu")
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
        .onAppear {
            if title.isEmpty && prBody.isEmpty { draft(with: appState.rememberedPullRequestModel) }
        }
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
