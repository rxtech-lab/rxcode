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

    var effectiveModel: String { appState.effectiveModelSelection(in: windowState).model }
    var effectiveProvider: AgentProvider { appState.effectiveModelSelection(in: windowState).provider }
    var flatModels: [AgentModel] { appState.availableAgentModelSections().flatMap(\.models) }

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Model")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

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
                                appState.setSessionModel(model.id, provider: model.provider, in: windowState)
                                dismiss()
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
        .background(ClaudeTheme.background)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            selectedIndex = (selectedIndex - 1 + flatModels.count) % flatModels.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = (selectedIndex + 1) % flatModels.count
            return .handled
        }
        .onKeyPress(.return) {
            let model = flatModels[selectedIndex]
            appState.setSessionModel(model.id, provider: model.provider, in: windowState)
            dismiss()
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

    // 0 = Auto (nil), 1...n = availableEfforts
    let items: [String?] = [nil] + AppState.availableEfforts.map { Optional($0) }

    var effectiveEffort: String? { windowState.sessionEffort }

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
                            Text(effort.map { effortDisplayName($0) } ?? "Auto")
                                .foregroundStyle(ClaudeTheme.textPrimary)
                            if effort == "max" {
                                Text("Opus 4.6 only")
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
    }
}
