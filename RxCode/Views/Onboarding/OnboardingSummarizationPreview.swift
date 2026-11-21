import RxCodeCore
import SwiftUI

struct SummarizationSetupPreview: View {
    let appState: AppState
    @Binding var endpointDraft: String
    @Binding var apiKeyDraft: String
    @Binding var hasLoadedModels: Bool

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Summarization Model")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Provider")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Menu {
                    Picker("", selection: $appState.summarizationProvider) {
                        ForEach(SummarizationProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Text(appState.summarizationProvider.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ClaudeTheme.surfaceSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            switch appState.summarizationProvider {
            case .selectedClient:
                Text("Uses the model picked by the current thread. No extra configuration needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            case .appleFoundationModel:
                Text("Runs on-device using Apple Intelligence. Free, private, and offline.")
                    .font(.system(size: 12))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            case .openAI:
                openAISection
            }
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ClaudeTheme.codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
        )
    }

    private var openAISection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 10) {
            labeledField(
                label: LocalizedStringKey("Endpoint"),
                placeholder: AppState.defaultOpenAISummarizationEndpoint,
                text: $endpointDraft
            )
            labeledSecureField(
                label: LocalizedStringKey("API Key"),
                placeholder: "sk-...",
                text: $apiKeyDraft
            )

            HStack(spacing: 8) {
                Picker("", selection: $appState.openAISummarizationModel) {
                    if !appState.openAISummarizationModel.isEmpty,
                       !appState.openAISummarizationModels.contains(appState.openAISummarizationModel) {
                        Text(verbatim: appState.openAISummarizationModel)
                            .tag(appState.openAISummarizationModel)
                    }
                    ForEach(appState.openAISummarizationModels, id: \.self) { model in
                        Text(verbatim: model).tag(model)
                    }
                    if appState.openAISummarizationModels.isEmpty && appState.openAISummarizationModel.isEmpty {
                        Text("Fetch models first").tag("")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280)

                Button {
                    persistDrafts()
                    Task { await appState.refreshOpenAISummarizationModels() }
                } label: {
                    HStack(spacing: 4) {
                        if appState.isLoadingOpenAISummarizationModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Fetch Models")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(ClaudeTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appState.isLoadingOpenAISummarizationModels)
            }

            if let error = appState.openAISummarizationModelsError {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
        }
        .onAppear {
            guard !hasLoadedModels else { return }
            hasLoadedModels = true
            persistDrafts()
            if appState.openAISummarizationModels.isEmpty {
                Task { await appState.refreshOpenAISummarizationModels() }
            }
        }
    }

    private func persistDrafts() {
        if endpointDraft != appState.openAISummarizationEndpoint {
            appState.openAISummarizationEndpoint = endpointDraft
        }
        if apiKeyDraft != appState.openAISummarizationAPIKey {
            appState.openAISummarizationAPIKey = apiKeyDraft
        }
    }

    private func labeledField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 78, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func labeledSecureField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 78, alignment: .leading)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
