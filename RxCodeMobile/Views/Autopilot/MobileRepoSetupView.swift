import JSONSchema
import JSONSchemaForm
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Repo-setup templates: reusable GitHub merge settings + branch rulesets
/// applied to new repositories. Mirrors the desktop `RepoSetupManageSheet`.
struct MobileRepoSetupView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var templates: [RepoSetupTemplate] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editingTemplate: EditingTarget?
    @State private var pendingDelete: RepoSetupTemplate?

    enum EditingTarget: Identifiable {
        case new
        case existing(RepoSetupTemplate)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let template): return template.id
            }
        }
    }

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Section {
                Text("Templates of GitHub merge settings and branch rulesets. The default template is applied to newly created repositories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(templates) { template in
                Button {
                    editingTemplate = .existing(template)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                if template.isDefault {
                                    Text("Default").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                                Text(template.enabled ? "Enabled" : "Disabled")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = template }
                }
            }
            if templates.isEmpty, !isLoading {
                Text("No templates yet. Tap + to create one.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Repo Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingTemplate = .new } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editingTemplate) { target in
            MobileRepoSetupEditor(target: target) { await reload() }
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .alert(
            "Delete template?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let template = pendingDelete { Task { await delete(template) } }
                pendingDelete = nil
            }
        }
        .mobileAutopilotLoadingOverlay(isLoading && templates.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            templates = try await state.repoSetupTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ template: RepoSetupTemplate) async {
        do {
            try await state.deleteRepoSetupTemplate(id: template.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileRepoSetupEditor: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let target: MobileRepoSetupView.EditingTarget
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var enabled = true
    @State private var isDefault = false

    @State private var schema: JSONSchema?
    @State private var uiSchema: [String: Any]?
    @State private var formData: FormData = .object(properties: [:])
    @State private var controller = JSONSchemaFormController()
    @State private var useFallback = false
    @State private var mergeSettingsJSON = "{}"

    @State private var rulesetJSON = ""

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var existing: RepoSetupTemplate? {
        if case .existing(let template) = target { return template }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if let loadError {
                    VStack(spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry") { Task { await load() } }
                    }
                } else {
                    Section("Template") {
                        TextField("Name", text: $name)
                        Toggle("Enabled", isOn: $enabled)
                        Toggle("Default for new repositories", isOn: $isDefault)
                    }

                    Section("Merge Settings") {
                        if useFallback {
                            Text("Form couldn't be rendered — edit raw JSON.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $mergeSettingsJSON)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 180)
                        } else if let schema {
                            JSONSchemaForm(
                                schema: schema,
                                uiSchema: uiSchema,
                                formData: $formData,
                                liveValidate: true,
                                showSubmitButton: false,
                                controller: controller
                            )
                        }
                    }

                    Section {
                        TextEditor(text: $rulesetJSON)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 140)
                    } header: {
                        Text("Branch Ruleset (optional)")
                    } footer: {
                        Text("Paste a GitHub ruleset JSON with name, target, enforcement, and rules.")
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || isLoading || loadError != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        if let existing {
            name = existing.name
            enabled = existing.enabled
            isDefault = existing.isDefault
            mergeSettingsJSON = existing.mergeSettings.prettyJSONString
            rulesetJSON = existing.rulesetConfig?.prettyJSONString ?? ""
        }
        do {
            let env = try await state.repoSetupSchema()
            uiSchema = env.uiSchema?.foundationObject as? [String: Any]
            do {
                let parsed = try JSONSchema(jsonString: env.schema.rawJSONString)
                let seedJSON = existing?.mergeSettings.rawJSONString ?? "{}"
                let seeded = try FormData.fromJSONString(seedJSON)
                formData = seeded.applyingDefaults(schema: parsed)
                schema = parsed
                useFallback = false
            } catch {
                useFallback = true
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // Merge settings
            let mergeSettings: JSONValue
            if useFallback {
                guard let data = mergeSettingsJSON.data(using: .utf8),
                      let parsed = try? JSONValue(jsonData: data) else {
                    errorMessage = "Merge settings must be valid JSON."
                    return
                }
                mergeSettings = parsed
            } else {
                let ok = try await controller.submit()
                guard ok else {
                    errorMessage = "Please fix the highlighted fields."
                    return
                }
                let data = try JSONEncoder().encode(formData)
                mergeSettings = try JSONValue(jsonData: data)
            }

            // Optional ruleset
            var rulesetConfig: JSONValue?
            let trimmedRuleset = rulesetJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRuleset.isEmpty {
                switch GitHubRulesetSummary.validate(rawJSON: trimmedRuleset) {
                case .success(let summary):
                    rulesetConfig = summary.value
                case .failure(let validationError):
                    errorMessage = validationError.localizedDescription
                    return
                }
            }

            let input = RepoSetupTemplateInput(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                enabled: enabled,
                isDefault: isDefault,
                mergeSettings: mergeSettings,
                rulesetConfig: rulesetConfig
            )
            if let existing {
                _ = try await state.updateRepoSetupTemplate(id: existing.id, input)
            } else {
                _ = try await state.createRepoSetupTemplate(input)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
