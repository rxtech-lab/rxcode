import JSONSchema
import JSONSchemaForm
import RxCodeCore
import SwiftUI

/// "Automation Settings" sheet: fetches the automation JSON Schema + current
/// values from github-pm, renders them as a native form via `JSONSchemaForm`,
/// and PUTs the edited values back. Mirrors the webapp's
/// `/dashboard/settings/automation` page.
struct AutomationSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var schema: JSONSchema?
    @State private var uiSchema: [String: Any]?
    @State private var formData: FormData = .object(properties: [:])
    @State private var controller = JSONSchemaFormController()

    /// Raw values JSON used by the fallback editor when the schema can't be
    /// rendered by the form package.
    @State private var fallbackJSON = "{}"
    @State private var useFallback = false

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Automation Settings").font(.headline)
            Text("Configure what autopilot does automatically on your repositories.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            errorState(loadError)
        } else if useFallback {
            fallbackEditor
        } else if let schema {
            Form {
                JSONSchemaForm(
                    schema: schema,
                    uiSchema: uiSchema,
                    formData: $formData,
                    liveValidate: true,
                    showSubmitButton: false,
                    controller: controller
                )
                .padding(16)
            }
            .formStyle(.grouped)
        }
    }

    private var fallbackEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This settings form couldn't be rendered. Edit the raw JSON instead.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $fallbackJSON)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        .padding(16)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Load / Save

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            async let schemaCall = appState.automationSchema()
            async let valuesCall = appState.automationValues()
            let (env, prefs) = try await (schemaCall, valuesCall)

            uiSchema = env.uiSchema?.foundationObject as? [String: Any]
            fallbackJSON = prefs.values.prettyJSONString
            do {
                let parsed = try JSONSchema(jsonString: env.schema.rawJSONString)
                let seeded = try FormData.fromJSONString(prefs.values.rawJSONString)
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
            let values: JSONValue
            if useFallback {
                guard let data = fallbackJSON.data(using: .utf8),
                      let parsed = try? JSONValue(jsonData: data)
                else {
                    errorMessage = "Settings must be valid JSON."
                    return
                }
                values = parsed
            } else {
                let ok = try await controller.submit()
                guard ok else {
                    errorMessage = "Please fix the highlighted fields."
                    return
                }
                let data = try JSONEncoder().encode(formData)
                values = try JSONValue(jsonData: data)
            }
            try await appState.saveAutomationValues(values)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
