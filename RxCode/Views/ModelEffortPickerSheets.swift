import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - Model Picker Sheet

struct ModelPickerSheet: View {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState
    @Environment(\.dismiss) var dismiss
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    @State private var pendingComputerUseModel: AgentModel?

    var effectiveModel: String { appState.effectiveModelSelection(in: windowState).model }
    var effectiveProvider: AgentProvider { appState.effectiveModelSelection(in: windowState).provider }
    var flatModels: [AgentModel] { appState.availableAgentModelSections().flatMap(\.models) }

    private func selectModel(_ model: AgentModel) {
        if model.provider == .codex, !appState.streamState(in: windowState).computerUseAcknowledged {
            pendingComputerUseModel = model
        } else {
            appState.setSessionModel(model.id, provider: model.provider, in: windowState)
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Model")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if let iconURL = section.iconURL {
                                    ACPIconView(url: iconURL, size: 14)
                                }
                                Text(section.title)
                                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                    .foregroundStyle(ClaudeTheme.textTertiary)
                            }
                            .padding(.horizontal, 4)

                            ForEach(section.models, id: \.key) { model in
                                let index = flatModels.firstIndex(where: { $0.key == model.key }) ?? 0
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.displayName)
                                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                                            .foregroundStyle(ClaudeTheme.textPrimary)
                                        Text(model.description)
                                            .font(.system(size: ClaudeTheme.size(11)))
                                            .foregroundStyle(ClaudeTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    if effectiveProvider == model.provider && effectiveModel == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(ClaudeTheme.accent)
                                            .padding(.top, 2)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(index == selectedIndex ? ClaudeTheme.accentSubtle : ClaudeTheme.surfacePrimary)
                                .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                                .onTapGesture {
                                    selectModel(model)
                                }
                            }
                        }
                    }
                }
            }

            Text("↑↓ Select  ↵ Confirm  esc Cancel")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(20)
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(ComputerUseSelectionConfirmation(pendingModel: $pendingComputerUseModel) {
            dismiss()
        })
        .background(ClaudeTheme.background)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            guard !flatModels.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex - 1 + flatModels.count) % flatModels.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !flatModels.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex + 1) % flatModels.count
            return .handled
        }
        .onKeyPress(.return) {
            guard flatModels.indices.contains(selectedIndex) else { return .ignored }
            let model = flatModels[selectedIndex]
            selectModel(model)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            selectedIndex = flatModels.firstIndex { $0.provider == effectiveProvider && $0.id == effectiveModel } ?? 0
            DispatchQueue.main.async { isFocused = true }
        }
    }
}

// MARK: - Effort Picker Sheet

struct EffortPickerSheet: View {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState
    @Environment(\.dismiss) var dismiss
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var provider: AgentProvider { appState.effectiveModelSelection(in: windowState).provider }

    /// This thread's provider's levels, not the union — the same list the
    /// composer's picker shows. 0 = Auto (nil), 1...n = the provider's levels.
    private var levels: [ReasoningLevel] { appState.reasoningLevels(for: provider) }

    private var items: [String?] { [nil] + levels.map { Optional($0.id) } }

    var effectiveEffort: String? { windowState.sessionEffort }

    private func displayName(_ effort: String?) -> String {
        // The clearing row names what it falls back to, the same way the
        // composer's menu does — "Auto" read as "the agent decides", which is
        // not what an unpinned session sends.
        guard let effort else { return appState.defaultEffortTitle(for: provider) }
        return levels.first { $0.id == effort }?.displayName ?? effortDisplayName(effort)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Effort Level")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            VStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    let effort = items[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(effort))
                                .foregroundStyle(ClaudeTheme.textPrimary)
                            // The backend's own one-liner for the level,
                            // replacing a subtitle that was hardcoded for a
                            // single Claude model.
                            if let detail = effort.flatMap({ id in
                                levels.first { $0.id == id }?.levelDescription
                            }) {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(ClaudeTheme.textTertiary)
                            }
                        }
                        Spacer()
                        if effectiveEffort == effort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ClaudeTheme.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(index == selectedIndex ? ClaudeTheme.accentSubtle : ClaudeTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                    .onTapGesture {
                        appState.setSessionEffort(effort, in: windowState)
                        dismiss()
                    }
                }
            }

            Text("↑↓ Select  ↵ Confirm  esc Cancel")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(20)
        .frame(width: 300)
        .background(ClaudeTheme.background)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = (selectedIndex + 1) % items.count
            return .handled
        }
        .onKeyPress(.return) {
            appState.setSessionEffort(items[selectedIndex], in: windowState)
            dismiss()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            selectedIndex = items.firstIndex(where: { $0 == effectiveEffort }) ?? 0
            DispatchQueue.main.async { isFocused = true }
        }
        // The sheet can be opened (⌘-shortcut, `/effort`) before the composer
        // has ever asked, so it fetches rather than assuming the cache is warm.
        .task {
            await appState.loadReasoningLevels(for: provider)
            selectedIndex = items.firstIndex(where: { $0 == effectiveEffort }) ?? 0
        }
    }
}

/// Acknowledges computer use without broadening the session's permission mode.
struct ComputerUseSelectionConfirmation: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Binding var pendingModel: AgentModel?
    var onConfirmed: () -> Void = {}

    func body(content: Content) -> some View {
        content.alert("Use Codex for this session?", isPresented: Binding(
            get: { pendingModel != nil },
            set: { if !$0 { pendingModel = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingModel = nil }
            Button("Confirm for This Session") {
                guard let model = pendingModel else { return }
                appState.updateState(windowState.currentSessionId ?? windowState.newSessionKey) {
                    $0.computerUseAcknowledged = true
                }
                appState.setSessionModel(model.id, provider: model.provider, in: windowState)
                pendingModel = nil
                onConfirmed()
            }
        } message: {
            Text("Codex may use computer-control tools to view your screen and interact with apps when available. Acknowledge computer use for the rest of this chat session. Existing tool permissions still apply.")
        }
        .onChange(of: windowState.currentSessionId) { _, _ in pendingModel = nil }
        .onChange(of: windowState.selectedProject?.id) { _, _ in pendingModel = nil }
    }
}
