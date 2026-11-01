import SwiftUI
import RxCodeCore

/// The selected model's own settings, generated from its README by the
/// studio's setup agent. Sits beside the studio's preset picker: its values
/// override the preset, and in Auto the agent chooses them for each prompt.
struct StudioModelConfigControl: View {
    @Environment(ChatBridge.self) private var chatBridge
    @AppStorage(StudioModelConfig.storageKey) private var saved = ""
    @AppStorage(StudioModelConfig.pendingStorageKey) private var pending = ""
    @State private var sheet: SheetRequest?

    let kind: LocalStudioKind

    private struct SheetRequest: Identifiable {
        let id = UUID()
        let modelID: String
        let regenerate: Bool
    }

    private var modelID: String? { chatBridge.studioModelID }
    private var config: StudioModelConfig? { modelID.flatMap { StudioModelConfig.decodeAll(saved)[$0] } }
    /// The setup agent is building this model's form after its download.
    private var isSettingUp: Bool {
        config == nil && modelID.map { StudioModelConfig.decodePending(pending).contains($0) } == true
    }

    var body: some View {
        if let modelID, !StudioParameterKey.supported(for: kind).isEmpty {
            if isSettingUp {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Setting Up…", bundle: .module)
                }
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .help(String(localized: "The setup agent is reading this model's README to build its settings", bundle: .module))
                .accessibilityIdentifier("studio-model-config-pending")
            } else {
                menu(modelID: modelID)
            }
        }
    }

    private func menu(modelID: String) -> some View {
            Menu {
                if let config {
                    Picker(String(localized: "Mode", bundle: .module), selection: Binding(get: { config.mode }, set: { mode in
                        var updated = config
                        updated.mode = mode
                        store(updated)
                    })) {
                        ForEach(StudioModelConfig.Mode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Divider()
                    Button(String(localized: "Model Settings…", bundle: .module)) {
                        sheet = SheetRequest(modelID: modelID, regenerate: false)
                    }
                    Button(String(localized: "Regenerate from README…", bundle: .module)) {
                        sheet = SheetRequest(modelID: modelID, regenerate: true)
                    }
                } else {
                    Button(String(localized: "Generate Settings from README…", bundle: .module)) {
                        sheet = SheetRequest(modelID: modelID, regenerate: true)
                    }
                }
            } label: {
                Label(label, systemImage: config?.mode == .auto ? "sparkles" : "doc.text.magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Settings generated from this model's README", bundle: .module))
            .accessibilityIdentifier("studio-model-config")
            .sheet(item: $sheet) { request in
                StudioModelConfigSheet(
                    modelID: request.modelID,
                    kind: kind,
                    modelName: chatBridge.modelDisplayName,
                    initial: StudioModelConfig.decodeAll(saved)[request.modelID],
                    generatesOnAppear: request.regenerate
                ) { store($0) }
            }
    }

    private var label: String {
        guard let config else { return String(localized: "Model Settings", bundle: .module) }
        return config.mode == .auto ? String(localized: "Auto", bundle: .module) : String(localized: "Model", bundle: .module)
    }

    private func store(_ config: StudioModelConfig) {
        var all = StudioModelConfig.decodeAll(saved)
        all[config.modelID] = config
        saved = StudioModelConfig.encodeAll(all)
    }
}

/// Edits one model's generated settings form on a cancellable draft.
struct StudioModelConfigSheet: View {
    @Environment(ChatBridge.self) private var chatBridge
    @Environment(\.dismiss) private var dismiss

    let modelID: String
    let kind: LocalStudioKind
    let modelName: String
    let generatesOnAppear: Bool
    let save: (StudioModelConfig) -> Void

    @State private var draft: StudioModelConfig?
    @State private var generating = false
    @State private var generation: Task<Void, Never>?
    @State private var errorMessage: String?

    init(modelID: String, kind: LocalStudioKind, modelName: String, initial: StudioModelConfig?,
         generatesOnAppear: Bool, save: @escaping (StudioModelConfig) -> Void) {
        self.modelID = modelID
        self.kind = kind
        self.modelName = modelName
        self.generatesOnAppear = generatesOnAppear
        self.save = save
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    form(draft)
                } else if generating {
                    // The overlay below shows the progress on its own.
                    Color.clear
                } else {
                    ContentUnavailableView {
                        Label(String(localized: "No Model Settings Yet", bundle: .module), systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("The setup agent reads \(modelName)'s README and builds the settings this model supports, with its recommended values.", bundle: .module)
                    } actions: {
                        Button(String(localized: "Generate from README", bundle: .module)) { generate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(generating)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "\(kind.title) Model Settings", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) {
                        generation?.cancel()
                        dismiss()
                    }
                }
                if draft != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(String(localized: "Regenerate", bundle: .module), systemImage: "arrow.clockwise") { generate() }
                            .help(String(localized: "Read the README again and rebuild this form", bundle: .module))
                            .disabled(generating)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) {
                        if let draft { save(draft) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || generating)
                }
            }
            .overlay {
                if generating {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the model card…", bundle: .module)
                            .font(.callout)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(String(localized: "Couldn't Generate Settings", bundle: .module), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "OK", bundle: .module), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .frame(width: 560, height: 660)
        .task {
            if generatesOnAppear { generate() }
        }
    }

    private func form(_ config: StudioModelConfig) -> some View {
        Form {
            Section {
                Picker(String(localized: "Mode", bundle: .module), selection: binding(\.mode)) {
                    ForEach(StudioModelConfig.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(config.mode == .auto
                     ? String(localized: "The setup agent reads each prompt and chooses these settings within the ranges below, starting from the values you set.", bundle: .module)
                     : String(localized: "These values apply to every generation with this model and override the quality preset.", bundle: .module))
            }
            Section {
                ForEach(config.parameters) { parameter in
                    control(parameter, value: config.resolvedValues[parameter.key] ?? parameter.defaultValue)
                }
                Button(String(localized: "Reset to Recommended", bundle: .module)) {
                    draft?.values = [:]
                }
                .disabled(config.values.isEmpty)
            } header: {
                Text("Settings", bundle: .module)
            }
            if config.summary != nil || config.generatedBy != nil {
                Section {
                    if let summary = config.summary {
                        Text(summary)
                            .textSelection(.enabled)
                    }
                    LabeledContent(String(localized: "Generated", bundle: .module)) {
                        Text([config.generatedBy, config.generatedAt.formatted(date: .abbreviated, time: .shortened)]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                } header: {
                    Text("From the Model Card", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func control(_ parameter: StudioParameter, value: StudioValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch parameter.control {
            case .choice:
                Picker(parameter.label, selection: valueBinding(parameter, current: value)) {
                    ForEach(parameter.options ?? [], id: \.self) { option in
                        Text(option.display).tag(option)
                    }
                }
            case .slider:
                let range = (parameter.minimum ?? 0)...max(parameter.minimum ?? 0, parameter.maximum ?? 1)
                Slider(value: numberBinding(parameter, current: value), in: range) {
                    Text(verbatim: "\(parameter.label): \(value.display)")
                }
            case .stepper:
                let low = parameter.minimum ?? 0
                let range = low...max(low, parameter.maximum ?? Double(Int32.max))
                Stepper(value: numberBinding(parameter, current: value), in: range, step: parameter.step ?? 1) {
                    Text(verbatim: "\(parameter.label): \(value.display)")
                }
            case .text:
                TextField(parameter.label, text: Binding(
                    get: { value.text ?? value.display },
                    set: { update(parameter, .text($0)) }
                ), axis: .vertical)
                .lineLimit(1...4)
            }
            if let help = parameter.help, !help.isEmpty {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<StudioModelConfig, Value>) -> Binding<Value> {
        Binding(get: { draft![keyPath: keyPath] }, set: { draft?[keyPath: keyPath] = $0 })
    }

    private func valueBinding(_ parameter: StudioParameter, current: StudioValue) -> Binding<StudioValue> {
        Binding(get: { current }, set: { update(parameter, $0) })
    }

    private func numberBinding(_ parameter: StudioParameter, current: StudioValue) -> Binding<Double> {
        Binding(get: { current.number ?? 0 }, set: { newValue in
            let stepped = parameter.step.map { step in (newValue / step).rounded() * step } ?? newValue
            update(parameter, .number((stepped * 100).rounded() / 100))
        })
    }

    private func update(_ parameter: StudioParameter, _ value: StudioValue) {
        guard let clean = parameter.sanitize(value) else { return }
        draft?.values[parameter.key] = clean
    }

    private func generate() {
        guard let handler = chatBridge.generateStudioConfigHandler, !generating else { return }
        generating = true
        let previous = draft
        generation = Task {
            defer { generating = false }
            do {
                let config = try await handler(modelID, previous)
                guard !Task.isCancelled else { return }
                draft = config
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
