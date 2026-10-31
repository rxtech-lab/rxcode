import AppKit
import RxCodeCore
import SwiftUI

/// Lists the engines the RxCode Agent runs local models with, and installs,
/// updates or removes them. llama.cpp and stable-diffusion.cpp are downloaded; MLX is linked into
/// RxCode, so installing or uninstalling it switches it on or off.
struct LocalRuntimesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var working: String?
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var pendingRemoval: LocalRuntimeComponent?

    private var store: LocalModelStore { appState.localModels }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(LocalRuntimeComponent.allCases) { component in
                        row(component)
                    }
                } header: {
                    Text("Engines")
                } footer: {
                    Text("llama.cpp and stable-diffusion.cpp are downloaded from their official GitHub releases; a Homebrew copy is used when RxCode has not installed one. MLX ships with RxCode and updates with it. Uninstalling an engine keeps its models on disk.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Runtimes")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await store.checkForRuntimeUpdates() }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    .help("Check for runtime updates")
                    .disabled(store.llamaUpdate == .checking || store.stableDiffusionUpdate == .checking || working != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { statusOverlay }
        .task { await store.checkForRuntimeUpdates() }
        .alert("Uninstall \(pendingRemoval?.title ?? "")?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { component in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Uninstall", role: .destructive) { uninstall(component) }
        } message: { component in
            switch component {
            case .llamaCpp:
                Text("RxCode's copy of llama.cpp will be deleted. GGUF models stay on disk and need the engine reinstalled before they run.")
            case .stableDiffusion:
                Text("RxCode's copy of stable-diffusion.cpp will be deleted. Diffusion models stay on disk and need the engine reinstalled before they run.")
            case .mlx:
                Text("The MLX engine will be turned off and any loaded MLX model unloaded. MLX models stay on disk and run again after you reinstall the engine.")
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Rows

    private func row(_ component: LocalRuntimeComponent) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: component.systemImage)
                .font(.system(size: ClaudeTheme.size(16)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.title)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                if let version = version(of: component) {
                    Text(version)
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(component.summary)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                stateLabel(component)
            }
            Spacer(minLength: 8)
            switch component {
            case .llamaCpp: llamaActions
            case .stableDiffusion: stableDiffusionActions
            case .mlx: mlxActions
            }
        }
        .padding(.vertical, 2)
    }

    private func version(of component: LocalRuntimeComponent) -> String? {
        switch component {
        case .mlx:
            guard store.mlxRuntime != nil else { return nil }
            return "v\(LocalRuntimeComponent.mlxSwiftVersion) · MLX Swift LM v\(LocalRuntimeComponent.mlxSwiftLMVersion)"
        case .llamaCpp:
            guard let runtime = store.runtime else { return nil }
            return runtime.version == "homebrew" ? "Homebrew" : runtime.version
        case .stableDiffusion:
            guard let runtime = store.stableDiffusionRuntime else { return nil }
            return runtime.version == "homebrew" ? "Homebrew" : runtime.version
        }
    }

    @ViewBuilder
    private func stateLabel(_ component: LocalRuntimeComponent) -> some View {
        switch component {
        case .mlx:
            if !LlamaRuntimeInstaller.isAppleSilicon {
                stateText("Requires a Mac with Apple silicon", systemImage: "xmark.circle", color: ClaudeTheme.statusError)
            } else if store.mlxRuntime != nil {
                stateText("Latest version · updates with RxCode", systemImage: "checkmark.circle.fill", color: ClaudeTheme.statusSuccess)
            } else {
                stateText("Not installed", systemImage: "arrow.down.circle", color: .secondary)
            }
        case .llamaCpp:
            downloadableState(installed: store.runtime != nil, managed: isManagedLlama, update: store.llamaUpdate)
        case .stableDiffusion:
            if !LlamaRuntimeInstaller.isAppleSilicon {
                stateText("Requires a Mac with Apple silicon", systemImage: "xmark.circle", color: ClaudeTheme.statusError)
            } else {
                downloadableState(installed: store.stableDiffusionRuntime != nil, managed: isManagedStableDiffusion,
                                  update: store.stableDiffusionUpdate)
            }
        }
    }

    @ViewBuilder
    private func downloadableState(installed: Bool, managed: Bool, update: LocalModelStore.RuntimeUpdateState) -> some View {
        if !installed {
            stateText("Not installed", systemImage: "arrow.down.circle", color: .secondary)
        } else if !managed {
            stateText("Managed by Homebrew", systemImage: "shippingbox", color: .secondary)
        } else {
            switch update {
            case .unknown:
                EmptyView()
            case .checking:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for updates…")
                }
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
            case .upToDate:
                stateText("Latest version", systemImage: "checkmark.circle.fill", color: ClaudeTheme.statusSuccess)
            case .available(let version):
                stateText("Update available: \(version)", systemImage: "arrow.up.circle.fill", color: ClaudeTheme.accent)
            case .failed:
                stateText("Could not check for updates", systemImage: "exclamationmark.triangle", color: ClaudeTheme.statusWarning)
            }
        }
    }

    private func stateText(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .foregroundStyle(color)
    }

    private var isManagedLlama: Bool {
        store.runtime.map { LlamaRuntimeInstaller.isManaged($0, appSupport: store.appSupport) } ?? false
    }

    private var isManagedStableDiffusion: Bool {
        store.stableDiffusionRuntime.map { StableDiffusionRuntimeInstaller.isManaged($0, appSupport: store.appSupport) } ?? false
    }

    @ViewBuilder
    private var llamaActions: some View {
        if store.runtime == nil || !isManagedLlama {
            Button(store.runtime == nil ? "Install" : "Install Managed Copy") { installLlama(updating: false) }
                .controlSize(.small)
                .disabled(working != nil)
        } else {
            HStack(spacing: 6) {
                if case .available = store.llamaUpdate {
                    Button("Update") { installLlama(updating: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(working != nil)
                }
                Menu("Manage…") {
                    Button("Reinstall") { installLlama(updating: true) }
                    Button("Show in Finder") { reveal(store.runtime?.path) }
                    Divider()
                    Button("Uninstall…", role: .destructive) { pendingRemoval = .llamaCpp }
                }
                .fixedSize()
                .controlSize(.small)
                .disabled(working != nil)
            }
        }
    }

    @ViewBuilder
    private var stableDiffusionActions: some View {
        if store.stableDiffusionRuntime == nil || !isManagedStableDiffusion {
            Button(store.stableDiffusionRuntime == nil ? "Install" : "Install Managed Copy") { installStableDiffusion(updating: false) }
                .controlSize(.small)
                .disabled(working != nil || !LlamaRuntimeInstaller.isAppleSilicon)
        } else {
            HStack(spacing: 6) {
                if case .available = store.stableDiffusionUpdate {
                    Button("Update") { installStableDiffusion(updating: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(working != nil)
                }
                Menu("Manage…") {
                    Button("Reinstall") { installStableDiffusion(updating: true) }
                    Button("Show in Finder") { reveal(store.stableDiffusionRuntime?.path) }
                    Divider()
                    Button("Uninstall…", role: .destructive) { pendingRemoval = .stableDiffusion }
                }
                .fixedSize()
                .controlSize(.small)
                .disabled(working != nil)
            }
        }
    }

    @ViewBuilder
    private var mlxActions: some View {
        if store.mlxRuntime == nil {
            Button("Install") { installMLX() }
                .controlSize(.small)
                .disabled(working != nil || !LlamaRuntimeInstaller.isAppleSilicon)
        } else {
            Menu("Manage…") {
                Button("Uninstall…", role: .destructive) { pendingRemoval = .mlx }
            }
            .fixedSize()
            .controlSize(.small)
            .disabled(working != nil)
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var statusOverlay: some View {
        if let text = working ?? status {
            HStack(spacing: 8) {
                if working != nil { ProgressView().controlSize(.small) }
                Text(text)
                Spacer()
                if working == nil { Button("Dismiss") { status = nil } }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
        }
    }

    // MARK: - Actions

    private func installLlama(updating: Bool) {
        working = updating ? "Updating llama.cpp…" : "Installing llama.cpp…"
        Task {
            defer { working = nil }
            do {
                if updating {
                    try await store.updateLlamaRuntime()
                } else {
                    try await store.installRuntime(for: .gguf)
                    await store.checkForRuntimeUpdates()
                }
                showStatus("llama.cpp \(store.runtime?.version ?? "") is installed.")
            } catch is CancellationError {
                showStatus("Install cancelled.")
            } catch LocalModelDownloader.DownloadError.cancelled {
                showStatus("Install cancelled.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func installStableDiffusion(updating: Bool) {
        working = updating ? "Updating stable-diffusion.cpp…" : "Installing stable-diffusion.cpp…"
        Task {
            defer { working = nil }
            do {
                try await store.installStableDiffusionRuntime()
                showStatus("stable-diffusion.cpp \(store.stableDiffusionRuntime?.version ?? "") is installed.")
            } catch is CancellationError {
                showStatus("Install cancelled.")
            } catch LocalModelDownloader.DownloadError.cancelled {
                showStatus("Install cancelled.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func installMLX() {
        Task {
            do {
                try await store.installRuntime(for: .mlx)
                showStatus("MLX is installed.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func uninstall(_ component: LocalRuntimeComponent) {
        pendingRemoval = nil
        working = "Uninstalling \(component.title)…"
        Task {
            defer { working = nil }
            do {
                switch component {
                case .llamaCpp:
                    try await store.removeLlamaRuntime()
                    showStatus(store.runtime == nil
                        ? "llama.cpp uninstalled."
                        : "RxCode's llama.cpp uninstalled. Using the Homebrew copy.")
                case .stableDiffusion:
                    try store.removeStableDiffusionRuntime()
                    showStatus(store.stableDiffusionRuntime == nil
                        ? "stable-diffusion.cpp uninstalled."
                        : "RxCode's stable-diffusion.cpp uninstalled. Using the Homebrew copy.")
                case .mlx:
                    await store.removeMLXRuntime()
                    showStatus("MLX uninstalled.")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    private func showStatus(_ text: String) {
        status = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if status == text { status = nil }
        }
    }
}
