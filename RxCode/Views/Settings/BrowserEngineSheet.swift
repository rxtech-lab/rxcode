import AppKit
import RxCodeCore
import SwiftUI

/// Dedicated sheet for choosing the in-app browser engine and downloading,
/// updating, or removing the optional Chrome for Testing runtime.
struct BrowserEngineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    private var manager: BrowserEngineManager { .shared }

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                runtimeSection
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Browser Engine")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await manager.checkForUpdates() }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    .help("Check for Chrome runtime updates")
                    .disabled(manager.updateState == .checking || manager.installState.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { statusOverlay }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: manager.statusBanner)
        .task {
            manager.refreshInstalled()
            await manager.checkForUpdates()
        }
        .alert("Uninstall Downloaded Chrome?", isPresented: $confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                Task { await manager.uninstallManagedChrome() }
            }
        } message: {
            Text("RxCode’s downloaded Chrome for Testing runtime will be deleted from Application Support. If no other Chrome runtime is available, the in-app browser will switch back to WebKit.")
        }
    }

    // MARK: - Sections

    private var engineSection: some View {
        Section {
            Picker("Engine", selection: Binding(
                get: { manager.selectedEngine },
                set: { newValue in
                    if newValue == .chrome && !manager.isChromeAvailable {
                        manager.installOrUpdateChrome(switchAfterInstall: true)
                    } else {
                        manager.selectedEngine = newValue
                    }
                }
            )) {
                ForEach(BrowserEngineKind.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .disabled(manager.installState.isBusy)
            .accessibilityIdentifier("browser-engine-picker")

            VStack(alignment: .leading, spacing: 4) {
                Text(manager.selectedEngine.summary)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                if manager.selectedEngine == .chrome && !manager.isChromeAvailable {
                    Text("Download Chrome below to activate the Chrome engine. WebKit is used until Chrome is ready.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.statusWarning)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("In-App Browser Engine")
        } footer: {
            Text("Switching engines reloads open tabs in the workspace browser while preserving their current URLs.")
        }
    }

    private var runtimeSection: some View {
        Section {
            managedChromeRow
            systemChromeRow
        } header: {
            Text("Chrome Runtime")
        } footer: {
            Text("Chrome for Testing is downloaded on demand from Google’s official release servers into Application Support and is never bundled inside RxCode.")
        }
    }

    private var managedChromeRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: ClaudeTheme.size(16)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("Chrome for Testing")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                if let managed = manager.managedRuntime {
                    Text(managed.version)
                        .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                managedStateSubtitle
            }
            Spacer(minLength: 8)
            managedChromeActions
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var managedStateSubtitle: some View {
        switch manager.installState {
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text("\(formatBytes(received)) of \(formatBytes(total))")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Starting download…")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
        case .extracting:
            Text("Extracting downloaded archive…")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        case .removing:
            Text("Removing downloaded runtime…")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        case .idle:
            if manager.managedRuntime != nil {
                switch manager.updateState {
                case .checking:
                    Text("Checking for updates…")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                case .available(let version):
                    Text("Update available: \(version)")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.accent)
                case .upToDate:
                    Text("Up to date · Installed in Application Support")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.statusWarning)
                        .lineLimit(2)
                case .idle:
                    Text("Installed in Application Support")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            } else {
                switch manager.updateState {
                case .available(let version):
                    Text("Not downloaded · Latest Stable \(version)")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                default:
                    Text("Not downloaded · Official Google Chrome for Testing build")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var managedChromeActions: some View {
        switch manager.installState {
        case .downloading:
            Button("Cancel") { manager.cancelInstall() }
                .controlSize(.small)
        case .extracting, .removing:
            ProgressView().controlSize(.small)
        case .idle:
            if manager.managedRuntime != nil {
                HStack(spacing: 8) {
                    if case .available = manager.updateState {
                        Button("Update") { manager.installOrUpdateChrome() }
                            .controlSize(.small)
                    }
                    Button("Uninstall", role: .destructive) { confirmUninstall = true }
                        .controlSize(.small)
                }
            } else {
                Button("Download") {
                    manager.installOrUpdateChrome(switchAfterInstall: true)
                }
                .controlSize(.small)
                .accessibilityIdentifier("browser-engine-download-chrome")
            }
        }
    }

    private var systemChromeRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "macwindow")
                .font(.system(size: ClaudeTheme.size(16)))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("System Google Chrome")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                if let system = manager.systemRuntime {
                    Text("Detected in /Applications (\(system.version))")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not installed in /Applications")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if manager.systemRuntime != nil {
                Toggle("Use as fallback", isOn: Binding(
                    get: { manager.useSystemChromeFallback },
                    set: { manager.useSystemChromeFallback = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Use installed /Applications/Google Chrome.app when Chrome for Testing is not downloaded")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status Overlay

    @ViewBuilder
    private var statusOverlay: some View {
        if let banner = manager.statusBanner {
            HStack(spacing: 10) {
                switch banner {
                case .working(let message):
                    ProgressView().controlSize(.small)
                    Text(message)
                case .finished(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                    Text(message)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    Text(message).lineLimit(3)
                    Button("Dismiss") { manager.statusBanner = nil }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner) {
                guard case .finished = banner else { return }
                try? await Task.sleep(for: .seconds(3))
                if manager.statusBanner == banner {
                    withAnimation { manager.statusBanner = nil }
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
