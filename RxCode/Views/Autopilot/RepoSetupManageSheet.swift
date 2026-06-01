import RxCodeCore
import SwiftUI

/// Top-level "Repo Setup" sheet: lists the user's repo-setup templates and
/// drills into an editor to create/edit/delete them. Account-level (not
/// per-repo), mirroring the webapp's `/dashboard/repo-setup` page.
struct RepoSetupManageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [RepoSetupTemplate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path = NavigationPath()
    @State private var pendingDelete: RepoSetupTemplate?

    enum Route: Hashable {
        case create
        case edit(RepoSetupTemplate)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Repo Setup")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { path.append(Route.create) } label: {
                            Label("New Template", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .create:
                        RepoSetupTemplateEditor(template: nil) { await reload() }
                    case .edit(let template):
                        RepoSetupTemplateEditor(template: template) { await reload() }
                    }
                }
        }
        .frame(width: 560, height: 560)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Text("Templates of GitHub merge settings and an optional branch ruleset. Your default template is applied automatically to new repositories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(templates) { template in
                NavigationLink(value: Route.edit(template)) {
                    RepoSetupTemplateRow(template: template)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDelete = template
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if templates.isEmpty, !isLoading, errorMessage == nil {
                Text("No templates yet. Create one to standardize new repositories.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if isLoading, templates.isEmpty { ProgressView() }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let template = pendingDelete
                Task { await delete(template) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            templates = try await appState.repoSetupTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ template: RepoSetupTemplate?) async {
        guard let template else { return }
        do {
            try await appState.deleteRepoSetupTemplate(id: template.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RepoSetupTemplateRow: View {
    let template: RepoSetupTemplate

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name.isEmpty ? "Untitled" : template.name).font(.body)
                    if template.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if !template.enabled {
                        Text("Disabled").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let ruleset = (template.rulesetConfig?.isNull == false) ? "ruleset attached" : "no ruleset"
        return "Merge settings · \(ruleset)"
    }
}
