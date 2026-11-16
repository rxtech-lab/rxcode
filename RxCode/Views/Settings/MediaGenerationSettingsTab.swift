import RxCodeCore
import SwiftUI

struct MediaModelMenu: View {
    let kind: MediaGenerationKind
    @Binding var selection: MediaGenerationSelection?
    let appState: AppState
    let cloudModels: [FlowcyMediaModel]

    var body: some View {
        Menu {
            Button("None") { selection = nil }
            if kind == .image {
                Section("Codex") { Button("Codex Image Generation") { selection = .codex } }
            }
            Section("Downloaded Models") {
                ForEach(appState.localModels.installed.filter { kind.supports($0) }) { model in
                    Button(model.displayName) { selection = .init(provider: .local, model: model.id) }
                }
            }
            Section("Flowcy") {
                ForEach(cloudModels.filter { $0.labels.contains(kind.rawValue) }) { model in
                    Button(model.alias) { selection = .init(provider: .flowcy, model: model.id) }
                }
            }
        } label: {
            Text(label).lineLimit(1)
        }
        .menuStyle(.borderedButton)
    }

    private var label: String {
        guard let selection else { return "Choose \(kind.title) Model" }
        switch selection.provider {
        case .codex: return "Codex Image Generation"
        case .local: return appState.localModels.installed.first { $0.id == selection.model }?.displayName ?? "Unavailable: \(selection.model)"
        case .flowcy: return "Flowcy · \(cloudModels.first { $0.id == selection.model }?.alias ?? selection.model)"
        }
    }
}

struct MediaGenerationSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var preferences = MediaGenerationPreferences.shared
    @State private var models: [FlowcyMediaModel] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Agent Media Tools") {
                ForEach(MediaGenerationKind.allCases) { kind in
                    LabeledContent("\(kind.title) Model") {
                        MediaModelMenu(kind: kind, selection: Binding(
                            get: { preferences.selection(kind) },
                            set: { preferences.selections[kind.rawValue] = $0 }
                        ), appState: appState, cloudModels: models)
                    }
                }
                Text("Available to Claude, Codex, ACP clients, and local chat agents through IDE media tools. Codex and downloaded image models can refine attached images. Flowcy currently generates images from text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Flowcy Catalog") {
                if !appState.rxAuth.isAuthenticated { Text("Sign in to Flowcy to load cloud media models.").foregroundStyle(.secondary) }
                Button("Refresh Models") { Task { await load() } }.disabled(loading)
                Text("Models are grouped by their image, video, and audio labels. Flowcy uses your signed-in account and account allowance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if appState.rxAuth.isAuthenticated { await load() } }
        .overlay { if loading { PetActionStatusOverlay(message: "Loading media models…").allowsHitTesting(false) } }
        .alert("Unable to Load Media Models", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { models = try await FlowcyMediaClient(auth: appState.rxAuth).allModels() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
