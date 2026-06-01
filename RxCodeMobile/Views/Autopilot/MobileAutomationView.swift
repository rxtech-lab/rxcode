import JSONSchema
import JSONSchemaForm
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Automation settings: fetches the automation JSON Schema + current values
/// from the paired Mac, renders them as a native form via `JSONSchemaForm`, and
/// saves edited values back. Mirrors the desktop `AutomationSettingsSheet`,
/// including the raw-JSON fallback when the schema can't be rendered.
struct MobileAutomationView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var schema: JSONSchema?
    @State private var uiSchema: [String: Any]?
    @State private var formData: FormData = .object(properties: [:])
    @State private var controller = JSONSchemaFormController()

    @State private var fallbackJSON = "{}"
    @State private var useFallback = false

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    var body: some View {
        Form {
            if isLoading {
                HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if let loadError {
                VStack(spacing: 8) {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Retry") { Task { await load() } }
                }
            } else if useFallback {
                Section {
                    Text("This settings form couldn't be rendered. Edit the raw JSON instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $fallbackJSON)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
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

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
            }
        }
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || isLoading || loadError != nil)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            async let schemaCall = state.automationSchema()
            async let valuesCall = state.automationValues()
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
        savedMessage = nil
        defer { isSaving = false }
        do {
            let values: JSONValue
            if useFallback {
                guard let data = fallbackJSON.data(using: .utf8),
                      let parsed = try? JSONValue(jsonData: data) else {
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
            try await state.saveAutomationValues(values)
            savedMessage = "Saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
