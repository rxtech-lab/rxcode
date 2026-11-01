import RxCodeCore
import SwiftUI

/// A studio's engine and setup agent: which engine runs its models, and
/// which agent finds missing components (text encoders, VAEs, vocoders,
/// projectors) the first time a model runs. Both are remembered per studio
/// and apply to future generations, so video and audio can use different
/// agents.
struct LocalStudioSettingsSheet: View {
    let kind: LocalStudioKind
    let appState: AppState
    let window: WindowState

    @Environment(\.dismiss) private var dismiss
    @State private var preferences: LocalStudioPreferences
    @State private var confirmsForget = false
    @State private var overlayMessage: String?

    /// `provider:model` of the chosen setup agent; empty for the default.
    private static let defaultAgentTag = ""

    init(kind: LocalStudioKind, appState: AppState, window: WindowState) {
        self.kind = kind
        self.appState = appState
        self.window = window
        _preferences = State(initialValue: LocalStudioPreferences.load(for: kind))
    }

    private var model: LocalModelInfo? {
        let selection = appState.effectiveModelSelection(in: window)
        guard selection.provider == .localAgent, let model = appState.localModels.model(id: selection.model),
              model.studioKind == kind else { return nil }
        return model
    }

    /// Every agent that can answer one-shot setup prompts: Claude, Codex and
    /// the ACP clients. RxCode's local agent can't, so it is left out.
    private var agentSections: [(id: String, title: String, provider: AgentProvider, iconURL: String?, models: [AgentModel])] {
        appState.availableAgentModelSections().filter { $0.provider != .localAgent && !$0.models.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let model {
                    Section(String(localized: "Model")) {
                        LabeledContent(String(localized: "Selected")) {
                            Label(model.displayName, systemImage: kind.systemImage)
                        }
                        if let task = model.huggingFaceMetadata?.categoryLabel {
                            LabeledContent(String(localized: "Hugging Face task"), value: task)
                        }
                    }
                }
                engineSection
                if model?.format != .mlx {
                    agentSection
                    if let model { savedSetupSection(model) }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "\(kind.title) Studio Setup"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .overlay(alignment: .bottom) {
                if let overlayMessage {
                    Label(overlayMessage, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: overlayMessage)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .onChange(of: preferences) { _, value in value.save(for: kind) }
    }

    // MARK: - Engine

    private var engineSection: some View {
        let engines = LocalGenerationEngine.engines(for: kind)
        let resolved = model.flatMap { LocalGenerationEngine.resolve(for: $0, preferences: preferences) }
        return Section {
            Picker(String(localized: "Engine"), selection: Binding(
                get: { preferences.engineID ?? "" },
                set: { preferences.engineID = $0.isEmpty ? nil : $0 }
            )) {
                Text(String(localized: "Automatic")).tag("")
                ForEach(engines) { engine in
                    Text(engine.title).tag(engine.id)
                }
            }
            ForEach(engines) { engine in
                let problem = model.flatMap { engine.incompatibility(with: $0) }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: engine == resolved ? "checkmark.circle.fill" : engine.runtime.systemImage)
                        .foregroundStyle(engine == resolved ? Color.accentColor : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.title).font(.callout.weight(.medium))
                        Text(engine.summary).font(.caption).foregroundStyle(.secondary)
                        if let problem {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .opacity(problem == nil ? 1 : 0.6)
            }
        } header: {
            Text(String(localized: "Engine"))
        } footer: {
            Text(String(localized: "Automatic uses the first engine that can run the selected model. A chosen engine that can't run a model falls back to automatic for it."))
        }
    }

    // MARK: - Setup agent

    private var agentSection: some View {
        let defaultLabel = appState.taskAgentLabel(appState.defaultTaskAgent())
        return Section {
            Picker(String(localized: "Setup agent"), selection: Binding(
                get: { preferences.setupAgent.map { "\($0.provider?.rawValue ?? ""):\($0.model ?? "")" } ?? Self.defaultAgentTag },
                set: { tag in
                    guard tag != Self.defaultAgentTag else { preferences.setupAgent = nil; return }
                    let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let provider = AgentProvider(rawValue: parts[0]) else { return }
                    preferences.setupAgent = TaskAgentConfig(provider: provider, model: parts[1])
                }
            )) {
                Text(String(localized: "Default task agent (\(defaultLabel))")).tag(Self.defaultAgentTag)
                ForEach(agentSections, id: \.id) { section in
                    Section(section.title) {
                        ForEach(section.models) { model in
                            Text(model.displayName).tag(model.key)
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "Setup Agent"))
        } footer: {
            Text(String(localized: "The first time a model runs, this agent reads its Hugging Face card and files to find the companion files it needs. RxCode only downloads files it has seen listed in the repository. The choice applies to this studio's future setups."))
        }
    }

    // MARK: - Saved setup

    private func savedSetupSection(_ model: LocalModelInfo) -> some View {
        let hasRecipe = appState.localModels.hasSavedRecipe(for: model)
        return Section {
            LabeledContent(String(localized: "Companion files")) {
                Text(hasRecipe ? String(localized: "Found and saved") : String(localized: "Looked up on the next run"))
                    .foregroundStyle(.secondary)
            }
            Button(String(localized: "Find Again on Next Run…"), role: .destructive) { confirmsForget = true }
                .disabled(!hasRecipe)
        } header: {
            Text(String(localized: "Saved Setup"))
        } footer: {
            Text(String(localized: "Ask the setup agent again, for example after choosing another agent or when generation keeps failing. Downloaded files stay on disk."))
        }
        .confirmationDialog(String(localized: "Find the companion files again?"), isPresented: $confirmsForget) {
            Button(String(localized: "Find Again"), role: .destructive) {
                appState.localModels.forgetRecipes(for: model)
                showOverlay(String(localized: "The next run looks up its setup again"))
            }
        } message: {
            Text(String(localized: "The saved setup for \(model.displayName) is cleared. The setup agent looks it up on the next generation."))
        }
    }

    private func showOverlay(_ message: String) {
        overlayMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            overlayMessage = nil
        }
    }
}

private struct LocalStudioSettingsSheetModifier: ViewModifier {
    @Bindable var windowState: WindowState
    let appState: AppState

    func body(content: Content) -> some View {
        content.sheet(item: $windowState.studioSettingsKind) { kind in
            LocalStudioSettingsSheet(kind: kind, appState: appState, window: windowState)
        }
    }
}

extension View {
    /// Presents `WindowState.studioSettingsKind`. Attach once per window root.
    func localStudioSettingsSheet(_ windowState: WindowState, appState: AppState) -> some View {
        modifier(LocalStudioSettingsSheetModifier(windowState: windowState, appState: appState))
    }
}
