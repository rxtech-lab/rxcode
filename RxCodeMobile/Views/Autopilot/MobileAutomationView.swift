import JSONSchema
import JSONSchemaForm
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Automation settings: fetches the automation JSON Schema + current values
/// from the active service, renders them as a native form via `JSONSchemaForm`, and
/// automatically saves edits. Mirrors the desktop `AutomationSettingsSheet`,
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
    @State private var debounceTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var savedDraft = ""
    @State private var savePending = false

    private var draft: String {
        if useFallback { return fallbackJSON }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(formData)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

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
        }
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear {
            debounceTask?.cancel()
            feedbackTask?.cancel()
            // Finish pending edits even when the user navigates away during debounce.
            Task { await save() }
        }
        .alert("Could Not Save Automation", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Retry") { Task { await save() } }
            Button("Cancel", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .overlay(alignment: .topTrailing) {
            if isSaving {
                ProgressView("Saving…")
                    .padding().background(.regularMaterial, in: Capsule()).padding()
                    .allowsHitTesting(false)
            } else if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill")
                    .padding().background(.regularMaterial, in: Capsule()).padding()
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
            savedDraft = draft
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func scheduleSave() {
        guard !isLoading, loadError == nil, draft != savedDraft else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            guard !Task.isCancelled else { return }
            // Keep an in-flight write separate from the cancellable debounce.
            Task { await save() }
        }
    }

    private func save() async {
        guard !isLoading, loadError == nil else { return }
        guard !isSaving else { savePending = true; return }
        guard draft != savedDraft else { return }
        var savingDraft = draft
        isSaving = true
        errorMessage = nil
        savedMessage = nil
        defer {
            isSaving = false
            if savePending {
                savePending = false
                Task { await save() }
            }
        }
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
                savingDraft = draft
                values = try JSONValue(jsonData: Data(savingDraft.utf8))
            }
            try await state.saveAutomationValues(values)
            savedDraft = savingDraft
            // A user can continue editing while the request is in flight,
            // including reverting to the previously saved value.
            if draft != savedDraft { savePending = true }
            savedMessage = "Saved automatically"
            MobileHaptics.connected()
            feedbackTask?.cancel()
            feedbackTask = Task {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                savedMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}
