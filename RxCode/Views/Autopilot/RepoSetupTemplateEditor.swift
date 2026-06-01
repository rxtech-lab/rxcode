import AppKit
import JSONSchema
import JSONSchemaForm
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Create/edit a repo-setup template. Mirrors the webapp's `template-form.tsx`:
/// the merge settings (name/enabled/mergeSettings) are rendered from the
/// repo-setup JSON Schema, and a GitHub branch ruleset is supplied by
/// importing/pasting its raw JSON.
struct RepoSetupTemplateEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let template: RepoSetupTemplate?
    /// Called after a successful save so the list can refresh.
    var onSaved: () async -> Void

    @State private var schema: JSONSchema?
    @State private var uiSchema: [String: Any]?
    @State private var formData: FormData = .object(properties: [:])
    @State private var controller = JSONSchemaFormController()

    /// Raw template JSON ({name, enabled, mergeSettings}) used by the fallback
    /// editor when the schema can't be rendered.
    @State private var fallbackJSON = "{}"
    @State private var useFallback = false

    @State private var isDefault: Bool
    @State private var rulesetText: String
    @State private var rulesetSummary: GitHubRulesetSummary?
    @State private var rulesetError: String?

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(template: RepoSetupTemplate?, onSaved: @escaping () async -> Void) {
        self.template = template
        self.onSaved = onSaved
        _isDefault = State(initialValue: template?.isDefault ?? false)
        if let ruleset = template?.rulesetConfig, ruleset.isNull == false {
            _rulesetText = State(initialValue: ruleset.prettyJSONString)
        } else {
            _rulesetText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .navigationTitle(template == nil ? "New Template" : "Edit Template")
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
                Text(loadError).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await load() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsForm
                    Divider()
                    Toggle(isOn: $isDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default template")
                            Text("Applied automatically to newly created repositories.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    rulesetSection
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var settingsForm: some View {
        if useFallback {
            VStack(alignment: .leading, spacing: 6) {
                Text("This form couldn't be rendered. Edit the raw template JSON instead (name, enabled, mergeSettings).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $fallbackJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
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

    private var rulesetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Git Ruleset").font(.headline)
                Spacer()
                Button {
                    importRuleset()
                } label: { Label("Import JSON…", systemImage: "square.and.arrow.down") }
                if !rulesetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(role: .destructive) {
                        rulesetText = ""
                        validateRuleset()
                    } label: { Text("Remove") }
                }
            }
            Text("Optional. Paste or import a GitHub ruleset JSON exported from your repository's branch-rules settings.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $rulesetText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: rulesetText) { _, _ in validateRuleset() }
            if let rulesetError {
                Text(rulesetError).foregroundStyle(.red).font(.caption)
            } else if let rulesetSummary {
                rulesetSummaryCard(rulesetSummary)
            }
        }
    }

    private func rulesetSummaryCard(_ summary: GitHubRulesetSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name).font(.callout).fontWeight(.medium)
                Text("\(summary.target) · \(summary.enforcement) · \(summary.ruleCount) rule\(summary.ruleCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                Task { await save() }
            } label: {
                if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || isLoading || loadError != nil)
        }
        .padding(16)
    }

    // MARK: - Ruleset handling

    private func validateRuleset() {
        let trimmed = rulesetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            rulesetSummary = nil
            rulesetError = nil
            return
        }
        switch GitHubRulesetSummary.validate(rawJSON: trimmed) {
        case .success(let summary):
            rulesetSummary = summary
            rulesetError = nil
        case .failure(let error):
            rulesetSummary = nil
            rulesetError = error.localizedDescription
        }
    }

    /// Opens an `NSOpenPanel` (rather than `.fileImporter`) for consistency with
    /// the rest of the app's file pickers.
    private func importRuleset() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? Data(contentsOf: url) {
            rulesetText = String(decoding: data, as: UTF8.self)
            validateRuleset()
        } else {
            rulesetError = "Couldn't read the selected file."
        }
    }

    // MARK: - Load / Save

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let env = try await appState.repoSetupSchema()
            uiSchema = env.uiSchema?.foundationObject as? [String: Any]

            // Reconstruct the schema-backed body (name/enabled/mergeSettings)
            // from the existing template, or empty for a new one.
            let seed: JSONValue = .object([
                "name": .string(template?.name ?? ""),
                "enabled": .bool(template?.enabled ?? true),
                "mergeSettings": template?.mergeSettings ?? .object([:]),
            ])
            fallbackJSON = seed.prettyJSONString
            do {
                let parsed = try JSONSchema(jsonString: env.schema.rawJSONString)
                let seeded = try FormData.fromJSONString(seed.rawJSONString)
                formData = seeded.applyingDefaults(schema: parsed)
                schema = parsed
                useFallback = false
            } catch {
                useFallback = true
            }
            validateRuleset()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        // Validate ruleset (if any) before touching the network.
        let trimmedRuleset = rulesetText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rulesetValue: JSONValue?
        if !trimmedRuleset.isEmpty {
            switch GitHubRulesetSummary.validate(rawJSON: trimmedRuleset) {
            case .success(let summary): rulesetValue = summary.value
            case .failure(let error):
                errorMessage = error.localizedDescription
                return
            }
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let body: JSONValue
            if useFallback {
                guard let data = fallbackJSON.data(using: .utf8),
                      let parsed = try? JSONValue(jsonData: data),
                      case .object = parsed else {
                    errorMessage = "Template must be a valid JSON object."
                    return
                }
                body = parsed
            } else {
                let ok = try await controller.submit()
                guard ok else {
                    errorMessage = "Please fix the highlighted fields."
                    return
                }
                let data = try JSONEncoder().encode(formData)
                body = try JSONValue(jsonData: data)
            }

            let name = (body["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                errorMessage = "Template name is required."
                return
            }
            let input = RepoSetupTemplateInput(
                name: name,
                enabled: body["enabled"]?.boolValue ?? true,
                isDefault: isDefault,
                mergeSettings: body["mergeSettings"] ?? .object([:]),
                rulesetConfig: rulesetValue
            )

            if let template {
                _ = try await appState.updateRepoSetupTemplate(id: template.id, input)
            } else {
                _ = try await appState.createRepoSetupTemplate(input)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
