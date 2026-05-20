import RxCodeCore
import RxCodeSync
import SwiftUI
import TipKit

struct MobileSettingsView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let showsDoneButton: Bool
    @State private var showPairingSheet = false
    @State private var desktopPendingRemoval: PairedDesktop?
    @State private var modelDraft = ""
    @State private var acpClientDraft = ""

    init(showsDoneButton: Bool = true) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        NavigationStack {
            Form {
                pairedMacsSection

                computerStatusSection

                desktopUsageSection

                if let settings = state.desktopSettings {
                    desktopBehaviorSection(settings)
                    desktopAutoPreviewSection(settings)
                    desktopSummarizationSection(settings)
                } else {
                    Section("Desktop Settings") {
                        ProgressView("Syncing settings…")
                    }
                }

                if state.isPaired {
                    desktopConfigurationSection
                }

                pairNewSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await state.refreshSnapshot()
            }
            .task {
                // Pull a fresh snapshot when Settings opens so the computer
                // status and usage reflect the desktop's current state rather
                // than whatever the last broadcast happened to carry.
                await state.refreshSnapshot()
            }
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showPairingSheet) {
                NavigationStack {
                    OnboardingView(showsCancelButton: true) {
                        showPairingSheet = false
                    }
                    .environmentObject(state)
                    .navigationTitle("Pair New Mac")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .alert(
                "Remove pairing?",
                isPresented: Binding(
                    get: { desktopPendingRemoval != nil },
                    set: { if !$0 { desktopPendingRemoval = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    if let desktop = desktopPendingRemoval {
                        Task { await state.removePairedDesktop(desktop) }
                    }
                    desktopPendingRemoval = nil
                }
            } message: {
                if let desktop = desktopPendingRemoval {
                    Text("This removes \(desktop.displayName.isEmpty ? "this Mac" : desktop.displayName) from this device. Other paired Macs stay available.")
                }
            }
            .onAppear {
                modelDraft = state.desktopSettings?.selectedModel ?? ""
                acpClientDraft = state.desktopSettings?.selectedACPClientId ?? ""
            }
            .onChange(of: state.desktopSettings?.selectedModel) { _, value in
                modelDraft = value ?? ""
            }
            .onChange(of: state.desktopSettings?.selectedACPClientId) { _, value in
                acpClientDraft = value ?? ""
            }
        }
    }

    private var pairedMacsSection: some View {
        Section {
            ForEach(state.pairedDesktops) { desktop in
                pairedMacRow(desktop)
            }
            HStack {
                Text("Connection")
                Spacer()
                connectionLabel
            }
        } header: {
            Text("Paired Macs")
        } footer: {
            Text("Select which Mac this device controls. Removing one pairing does not reset this device's identity.")
        }
    }

    private func pairedMacRow(_ desktop: PairedDesktop) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(desktop.displayName.isEmpty ? "Unknown Mac" : desktop.displayName)
                    .foregroundStyle(.primary)
                Text("Paired \(desktop.pairedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if desktop.pubkeyHex == state.pairedDesktopPubkey {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Active")
            } else {
                Button {
                    Task { await state.switchPairedDesktop(desktop) }
                } label: {
                    Label("Switch", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Switch to \(desktop.displayName.isEmpty ? "Mac" : desktop.displayName)")
            }
            Button(role: .destructive) {
                desktopPendingRemoval = desktop
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(desktop.displayName.isEmpty ? "Mac" : desktop.displayName)")
        }
    }

    /// Links to the remote desktop-management screens: skill marketplace, ACP
    /// agent clients, and MCP servers. Shown only while paired since every
    /// action targets the active Mac.
    private var desktopConfigurationSection: some View {
        Section {
            NavigationLink {
                MobileSkillMarketView()
            } label: {
                Label("Skills", systemImage: "puzzlepiece.extension")
            }
            NavigationLink {
                MobileACPClientsView()
            } label: {
                Label("Agent Clients", systemImage: "cpu")
            }
            NavigationLink {
                MobileMCPServersView()
            } label: {
                Label("MCP Servers", systemImage: "server.rack")
            }
        } header: {
            Text("Desktop Configuration")
        } footer: {
            Text("Install skills and agents, and configure MCP servers on the active Mac.")
        }
    }

    private var pairNewSection: some View {
        Section {
            Button {
                showPairingSheet = true
            } label: {
                Label("Pair New Mac", systemImage: "plus.circle")
            }
            .popoverTip(MobileTips.PairingTip(), arrowEdge: .top)
        }
    }

    /// Agent rate-limit usage mirrored from the paired desktop. Renders one
    /// section per provider that reported usage; falls back to a hint when the
    /// desktop synced a usage payload but neither agent is signed in. Renders
    /// nothing at all when paired with a desktop that predates usage sync.
    @ViewBuilder
    private var desktopUsageSection: some View {
        if let usage = state.desktopUsage {
            if usage.hasAnyUsage {
                if let claude = usage.claudeCode {
                    Section("Claude Code Usage") {
                        MetricBar(
                            label: "5-hour limit",
                            percent: claude.fiveHourPercent,
                            valueText: Self.percentText(claude.fiveHourPercent),
                            caption: Self.resetCaption(claude.fiveHourResetsAt)
                        )
                        MetricBar(
                            label: "7-day limit",
                            percent: claude.sevenDayPercent,
                            valueText: Self.percentText(claude.sevenDayPercent),
                            caption: Self.resetCaption(claude.sevenDayResetsAt)
                        )
                    }
                }
                if let codex = usage.codex {
                    Section("Codex Usage") {
                        MetricBar(
                            label: "5-hour limit",
                            percent: codex.fiveHourPercent,
                            valueText: Self.percentText(codex.fiveHourPercent),
                            caption: Self.resetCaption(codex.fiveHourResetsAt)
                        )
                        if let twentyFour = codex.twentyFourHourPercent {
                            MetricBar(
                                label: "24-hour limit",
                                percent: twentyFour,
                                valueText: Self.percentText(twentyFour),
                                caption: Self.resetCaption(codex.twentyFourHourResetsAt)
                            )
                        }
                    }
                }
            } else {
                Section("Usage") {
                    Text("Sign in to Claude Code or Codex on your Mac to see usage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Live CPU / memory / thermal load mirrored from the active paired desktop.
    /// Renders nothing when paired with a desktop that predates this sync.
    @ViewBuilder
    private var computerStatusSection: some View {
        if let metrics = state.desktopHostMetrics {
            Section {
                MetricBar(
                    label: "CPU",
                    percent: metrics.cpuUsagePercent,
                    valueText: Self.percentText(metrics.cpuUsagePercent)
                )
                MetricBar(
                    label: "Memory",
                    percent: metrics.memoryUsedPercent,
                    valueText: Self.formatBytes(metrics.memoryUsedBytes),
                    caption: "of \(Self.formatBytes(metrics.memoryTotalBytes))"
                )
                HStack {
                    Text("Thermal")
                    Spacer()
                    Text(Self.thermalLabel(metrics.thermalState))
                        .foregroundStyle(Self.thermalColor(metrics.thermalState))
                }
            } header: {
                Text("Computer Status")
            } footer: {
                Text("Updated \(metrics.sampledAt, format: .relative(presentation: .named)). Pull to refresh.")
            }
        }
    }

    /// Format a 0–100 utilization value as a percentage string, keeping one
    /// decimal for sub-1% values so light usage doesn't read as a flat "0%".
    private static func percentText(_ value: Double) -> String {
        if value > 0 && value < 1 {
            return String(format: "%.1f%%", value)
        }
        return "\(Int(value.rounded()))%"
    }

    /// Relative "Resets …" caption for a rate-limit window, or `nil` when the
    /// desktop didn't report a reset time.
    private static func resetCaption(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "Resets \(date.formatted(.relative(presentation: .named)))"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory))
    }

    private static func thermalLabel(_ state: HostMetricsSnapshot.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    private static func thermalColor(_ state: HostMetricsSnapshot.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func desktopBehaviorSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section("Desktop Behavior") {
            Toggle("Response notifications", isOn: settingBinding(settings.notificationsEnabled) { value in
                MobileSettingsUpdatePayload(notificationsEnabled: value)
            })
            Toggle("Focus mode", isOn: settingBinding(settings.focusMode) { value in
                MobileSettingsUpdatePayload(focusMode: value)
            })
            Toggle("Auto-archive", isOn: settingBinding(settings.autoArchiveEnabled) { value in
                MobileSettingsUpdatePayload(autoArchiveEnabled: value)
            })
            Stepper(
                "Archive after \(settings.archiveRetentionDays) day\(settings.archiveRetentionDays == 1 ? "" : "s")",
                value: settingBinding(settings.archiveRetentionDays) { value in
                    MobileSettingsUpdatePayload(archiveRetentionDays: value)
                },
                in: 1 ... 365
            )
            .disabled(!settings.autoArchiveEnabled)
        }
    }

    private func desktopAutoPreviewSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section("Attachment Auto-Preview") {
            Toggle("URLs", isOn: autoPreviewBinding(settings, \.url))
            Toggle("File paths", isOn: autoPreviewBinding(settings, \.filePath))
            Toggle("Images", isOn: autoPreviewBinding(settings, \.image))
            Toggle("Long text", isOn: autoPreviewBinding(settings, \.longText))
        }
    }

    private func desktopSummarizationSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section {
            Picker(
                "Provider",
                selection: settingBinding(settings.summarizationProvider) { value in
                    MobileSettingsUpdatePayload(summarizationProvider: value)
                }
            ) {
                ForEach(settings.availableSummarizationProviders ?? []) { option in
                    Text(option.displayName).tag(option.id)
                }
                // Keep the current value selectable when the desktop is too
                // old to send the options list, or sent one without it.
                if settings.availableSummarizationProviders?
                    .contains(where: { $0.id == settings.summarizationProvider }) != true {
                    Text(settings.summarizationProviderDisplayName)
                        .tag(settings.summarizationProvider)
                }
            }
            .pickerStyle(.menu)
            .popoverTip(MobileTips.SummarizationTip(), arrowEdge: .top)

            if settings.summarizationProvider == "openAI" {
                if !settings.openAISummarizationEndpoint.isEmpty {
                    LabeledContent("Endpoint", value: settings.openAISummarizationEndpoint)
                }
                summarizationModelPicker(settings)
            }
        } header: {
            Text("Summarization")
        } footer: {
            Text("API keys stay on the Mac and are not synced to this device.")
        }
    }

    /// Model control for the OpenAI-compatible summarization endpoint. Shows a
    /// picker once the desktop has synced its fetched model list; falls back to
    /// a read-only row while that list is still empty.
    @ViewBuilder
    private func summarizationModelPicker(_ settings: MobileSettingsSnapshot) -> some View {
        let models = settings.openAISummarizationModels ?? []
        if models.isEmpty {
            if !settings.openAISummarizationModel.isEmpty {
                LabeledContent("Model", value: settings.openAISummarizationModel)
            }
        } else {
            Picker(
                "Model",
                selection: settingBinding(settings.openAISummarizationModel) { value in
                    MobileSettingsUpdatePayload(openAISummarizationModel: value)
                }
            ) {
                // Preserve a current value the desktop's list doesn't contain.
                if !settings.openAISummarizationModel.isEmpty,
                   !models.contains(settings.openAISummarizationModel) {
                    Text(settings.openAISummarizationModel)
                        .tag(settings.openAISummarizationModel)
                }
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func settingBinding<Value>(
        _ value: Value,
        update: @escaping (Value) -> MobileSettingsUpdatePayload
    ) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                Task { await state.updateDesktopSettings(update(newValue)) }
            }
        )
    }

    private func autoPreviewBinding(
        _ settings: MobileSettingsSnapshot,
        _ keyPath: WritableKeyPath<AttachmentAutoPreviewSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings.autoPreviewSettings[keyPath: keyPath] },
            set: { newValue in
                var next = settings.autoPreviewSettings
                next[keyPath: keyPath] = newValue
                Task {
                    await state.updateDesktopSettings(
                        MobileSettingsUpdatePayload(autoPreviewSettings: next)
                    )
                }
            }
        )
    }

    private func applyModelDraft() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await state.updateDesktopSettings(MobileSettingsUpdatePayload(selectedModel: trimmed)) }
    }

    private func applyACPClientDraft() {
        let trimmed = acpClientDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await state.updateDesktopSettings(MobileSettingsUpdatePayload(selectedACPClientId: trimmed)) }
    }

    private func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return effort.capitalized
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch state.connectionState {
        case .connected:
            Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
        case .disconnected:
            Label("Disconnected", systemImage: "circle.slash").foregroundStyle(.secondary)
        case .reconnecting(let seconds):
            Label("Reconnecting in \(seconds)s", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
        }
    }
}

/// A labeled progress bar with a trailing value and optional caption. Shared by
/// the agent usage sections and the computer-status section, mirroring the
/// desktop menu-bar usage bar.
private struct MetricBar: View {
    let label: String
    /// 0–100, drives the bar's fill width and color.
    let percent: Double
    /// Trailing value text on the label row, e.g. "42%" or "8.1 GB".
    let valueText: String
    /// Optional small line below the bar, e.g. "Resets in 2h" or "of 16 GB".
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(Self.barColor(for: percent))

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Green up to 60%, amber to 85%, red past it — same thresholds the desktop
    /// usage bar uses.
    static func barColor(for percent: Double) -> Color {
        switch percent {
        case ..<60: return ClaudeTheme.accent
        case ..<85: return .orange
        default: return .red
        }
    }
}
