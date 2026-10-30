import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

struct DeveloperSettingsTab: View {
    @Bindable private var recorder = CodingAnalyticsRecorder.shared
    @State private var action: CodingDataAction?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SettingsIconTile(systemImage: "chart.bar.xaxis", color: .indigo, size: 56)
                    Text("Coding Analytics")
                        .font(.title2.weight(.semibold))
                    Text("Understand how you work with Claude Code, Codex and ACP clients. Everything stays on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Toggle(isOn: $recorder.enabled.animation(.snappy)) {
                    SettingsRowLabel(
                        title: "Record Coding Behavior",
                        subtitle: "Starts with your next prompt",
                        systemImage: "record.circle",
                        color: .red
                    )
                }
            } footer: {
                Text("Records prompts, model history, usage-limit snapshots, session timing, reported tokens and ratings. Nothing is uploaded automatically.")
                    .settingsFooterStyle()
            }

            Section {
                LabeledContent {
                    Button("Export…") { action = .export }
                } label: {
                    SettingsRowLabel(
                        title: "Export Data",
                        subtitle: "ZIP with analytics and chat history",
                        systemImage: "square.and.arrow.up",
                        color: .blue
                    )
                }
                LabeledContent {
                    Button("Delete…", role: .destructive) { action = .delete }
                } label: {
                    SettingsRowLabel(
                        title: "Delete Data",
                        subtitle: "Your chats are kept",
                        systemImage: "trash",
                        color: .gray
                    )
                }
            } header: {
                Text("Your Data")
            } footer: {
                Label("Turning recording off keeps existing data. Exported files contain your prompt text.", systemImage: "lock.fill")
                    .settingsFooterStyle()
            }
        }
        .formStyle(.grouped)
        .sheet(item: $action) { CodingDataActionSheet(action: $0) }
        .alert("Coding Analytics Error", isPresented: Binding(
            get: { recorder.error != nil }, set: { if !$0 { recorder.error = nil } }
        )) { Button("OK") { recorder.error = nil } } message: { Text(recorder.error ?? "") }
    }
}

private struct SettingsIconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconTile(systemImage: systemImage, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    func settingsFooterStyle() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}

private enum CodingDataAction: String, Identifiable {
    case export, delete
    var id: String { rawValue }
    var title: String { self == .export ? "Export Coding Analytics" : "Delete Coding Analytics" }
}

private struct CodingDataActionSheet: View {
    let action: CodingDataAction
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var exportProgress: CodingAnalyticsExportProgress?

    var body: some View {
        NavigationStack {
            Form {
                Text(action == .export
                     ? "Export a ZIP with analytics and the full available chat history of recorded sessions. All providers use a shared message format, including text, tool calls and results. Attachment files are not included. Unavailable histories are listed in the manifest."
                     : "Permanently delete all recorded coding analytics and ratings from this Mac. Your chats and previously exported files are kept.")
                if action == .delete {
                    Button("Delete All Analytics…", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(busy)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(action.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(busy)
                }
                if action == .export {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Choose Export Location…") { performExport() }
                            .disabled(busy)
                    }
                }
            }
            .overlay {
                if busy {
                    progressOverlay
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                else if let status { Text(status).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) }
            }
        }
        .frame(width: 520, height: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Delete all coding analytics?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete All Analytics", role: .destructive) {
                busy = true
                status = nil
                Task {
                    defer { busy = false }
                    do { try await CodingAnalyticsRecorder.shared.deleteAll(); status = "Coding analytics deleted." }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .alert("Coding Analytics Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var progressOverlay: some View {
        if action == .delete {
            ProgressView("Deleting…")
        } else if let exportProgress {
            VStack(spacing: 10) {
                switch exportProgress.phase {
                case .histories:
                    ProgressView(value: Double(exportProgress.completed), total: Double(max(exportProgress.total, 1)))
                    Text("Exporting chat histories: \(exportProgress.completed) of \(exportProgress.total)")
                        .monospacedDigit()
                case .compressing:
                    ProgressView("Compressing ZIP…")
                case .saving:
                    ProgressView("Saving ZIP…")
                }
            }
            .frame(width: 280)
            .accessibilityElement(children: .combine)
        } else {
            ProgressView("Preparing export…")
        }
    }

    private func performExport() {
        busy = true
        status = nil
        exportProgress = nil
        Task {
            defer { busy = false; exportProgress = nil }
            guard let destination = await chooseExportDestination() else { return }
            do {
                let result = try await appState.exportCodingAnalytics(to: destination) { progress in
                    await MainActor.run { exportProgress = progress }
                }
                status = result.unavailableHistoryCount == 0
                    ? "Exported \(result.sessionCount) sessions."
                    : "Exported \(result.sessionCount) sessions. \(result.unavailableHistoryCount) chat histories were unavailable; see manifest.json."
            } catch { self.error = error.localizedDescription }
        }
    }

    @MainActor private func chooseExportDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "rxcode-coding-analytics.zip"
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
    }
}
