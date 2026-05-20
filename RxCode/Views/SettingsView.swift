import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

// MARK: - Settings Sheet

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedTab = 0
    @State private var showUserManual = false
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(
                showUserManual: $showUserManual,
                showOnboarding: $showOnboarding
            )
            .tabItem {
                Label("General", systemImage: "slider.horizontal.3")
            }
            .tag(0)

            ChatSettingsTab()
                .tabItem {
                    Label("Message", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(1)

            SlashCommandManagerView(isEmbedded: true)
                .tabItem {
                    Label("Slash Commands", systemImage: "terminal.fill")
                }
                .tag(2)

            ShortcutManagerView(isEmbedded: true)
                .tabItem {
                    Label("Shortcuts", systemImage: "bolt.fill")
                }
                .tag(3)

            SkillMarketView(isEmbedded: true)
                .tabItem {
                    Label("Skill Marketplace", systemImage: "brain.head.profile")
                }
                .tag(4)

            MCPSettingsTab()
                .tabItem {
                    Label("MCP", systemImage: "puzzlepiece.extension")
                }
                .tag(5)

            ACPClientSettingsTab()
                .tabItem {
                    Label("ACP Clients", systemImage: "link.circle")
                }
                .tag(6)

            MobileSettingsTab()
                .tabItem {
                    Label("Mobile", systemImage: "iphone.gen3")
                }
                .tag(7)
        }
        .frame(width: 680, height: 620)
        .focusable(false)
        .onAppear { selectedTab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Settings" else { return }
            selectedTab = 0
        }
        .sheet(isPresented: $showUserManual) {
            UserManualView()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
            }
            .environment(appState)
        }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Binding var showUserManual: Bool
    @Binding var showOnboarding: Bool
    @State private var showThemePicker = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                themeSection
                Divider()
                fontSizeSection
                Divider()
                notificationsSection(appState: $appState.notificationsEnabled)
                Divider()
                menuBarSection
                Divider()
                searchIndexSection
                Divider()
                MemorySettingsSection()
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    onboardingSection
                    helpSection
                    sourceCodeSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Search Index Section

    private var searchIndexSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Index")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reindex all threads")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Wipe cached embeddings and re-embed every thread for semantic search. Use this if global search results look stale or empty.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await appState.reindexAllThreads() }
                } label: {
                    if let progress = appState.reindexProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if progress.total > 0 {
                                Text(verbatim: "\(progress.done)/\(progress.total)")
                                    .font(.system(size: ClaudeTheme.size(12)))
                                    .monospacedDigit()
                            }
                        }
                    } else {
                        Text("Reindex Now")
                    }
                }
                .disabled(appState.reindexProgress != nil)
            }
        }
    }

    // MARK: - Menu Bar Section

    private var menuBarSection: some View {
        toggleSection(
            title: "Menu Bar",
            label: "Show menu bar icon",
            detail: "Shows in-progress chat counts and Claude Code usage limits in the macOS menu bar.",
            isOn: $showMenuBarExtra
        )
    }

    // MARK: - Toggle Section

    private func toggleSection(
        title: LocalizedStringKey,
        label: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text(detail)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Font Size Section

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Size")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            fontSizeRow(
                label: "Interface",
                value: appState.fontSizeAdjustment,
                onDecrease: { appState.decreaseFontSize() },
                onIncrease: { appState.increaseFontSize() },
                onReset: { appState.fontSizeAdjustment = 0 }
            )
            fontSizeRow(
                label: "Messages",
                value: appState.messageFontSizeAdjustment,
                onDecrease: { appState.decreaseMessageFontSize() },
                onIncrease: { appState.increaseMessageFontSize() },
                onReset: { appState.messageFontSizeAdjustment = 0 }
            )
            Text("font.size.hint")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private func fontSizeRow(label: LocalizedStringKey, value: Int, onDecrease: @escaping () -> Void, onIncrease: @escaping () -> Void, onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            fontStepButton(systemName: "minus", action: onDecrease)
                .disabled(value <= ThemeStore.minFontSizeAdjustment)
            Group {
                if value == 0 {
                    Text("Default")
                } else {
                    Text(verbatim: value > 0 ? "+\(value)" : "\(value)")
                }
            }
            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
            .frame(minWidth: 48, alignment: .center)
            fontStepButton(systemName: "plus", action: onIncrease)
                .disabled(value >= ThemeStore.maxFontSizeAdjustment)
            if value != 0 {
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.accent)
            }
        }
    }

    private func fontStepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 26, height: 26)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notifications Section

    private func notificationsSection(appState: Binding<Bool>) -> some View {
        toggleSection(
            title: "Notifications",
            label: "Notify when response completes",
            detail: "Sends a system notification while RxCode is in the background.",
            isOn: appState
        )
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Button {
                showThemePicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.selectedTheme.colors.accent)
                        .frame(width: 10, height: 10)
                    Text(appState.selectedTheme.displayName)
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemePickerRow(
                            theme: theme,
                            isSelected: appState.selectedTheme == theme
                        ) {
                            appState.selectedTheme = theme
                            showThemePicker = false
                        }
                    }
                }
                .padding(4)
                .frame(minWidth: 220)
                .focusable(false)
            }
        }
    }

    // MARK: - Source Code Section

    private var sourceCodeSection: some View {
        Link(destination: URL(string: "https://github.com/rxtech-lab/rxcode")!) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Source")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Text(verbatim: "github.com/rxtech-lab/rxcode")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Help Section

    private var onboardingSection: some View {
        Button {
            showOnboarding = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show Onboarding")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.primary)
                    Text("Review the CLI setup check")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var helpSection: some View {
        Button {
            showUserManual = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .font(.system(size: ClaudeTheme.size(14)))
                    .frame(width: 20)
                Text("User Guide")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chat Settings Tab

struct ChatSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var isRefreshingAgentStatus = false

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                agentRuntimeSection
                Divider()
                modelSection
                Divider()
                summarizationSection
                Divider()
                permissionModeSection
                Divider()
                effortSection
                Divider()
                focusModeSection
                Divider()
                autoPreviewSection
                Divider()
                archiveSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Agent Runtime Section

    private var agentRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent Runtimes")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

                Spacer()

                Button {
                    Task {
                        isRefreshingAgentStatus = true
                        await appState.refreshAgentInstallations()
                        isRefreshingAgentStatus = false
                    }
                } label: {
                    if isRefreshingAgentStatus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingAgentStatus)
                .help("Refresh installation status")
            }

            VStack(spacing: 8) {
                agentRuntimeRow(
                    title: "Claude Code",
                    installed: appState.claudeInstalled,
                    version: appState.claudeVersion,
                    path: appState.claudeBinaryPath
                )
                agentRuntimeRow(
                    title: "Codex",
                    installed: appState.codexInstalled,
                    version: appState.codexVersion,
                    path: appState.codexBinaryPath
                )
            }
        }
    }

    private func agentRuntimeRow(
        title: String,
        installed: Bool,
        version: String?,
        path: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                .font(.system(size: ClaudeTheme.size(14)))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text(installed ? "Installed" : "Not found")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                    if let version, !version.isEmpty {
                        Text(version)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(path ?? "No executable detected")
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(path == nil ? .secondary : ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Archive Section

    private var archiveSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Archive")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Inactive chats are moved to the archive automatically. Pinned chats are never auto-archived.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.autoArchiveEnabled) {
                Text("Auto-archive inactive chats")
            }
            .toggleStyle(.switch)
            .fixedSize()

            HStack(spacing: 10) {
                Text("Archive after")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: $appState.archiveRetentionDays,
                    in: 1...365
                ) {
                    Text("\(appState.archiveRetentionDays) day\(appState.archiveRetentionDays == 1 ? "" : "s") of inactivity")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                }
                .fixedSize()
            }
            .disabled(!appState.autoArchiveEnabled)
            .opacity(appState.autoArchiveEnabled ? 1 : 0.5)
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default Model")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the model per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: defaultModelKey) {
                ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.key) { model in
                            Text(model.displayName).tag(model.key)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(selectedDefaultModel.description)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var defaultModelKey: Binding<String> {
        Binding(
            get: { "\(appState.selectedAgentProvider.rawValue):\(appState.selectedModel)" },
            set: { key in
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let provider = AgentProvider(rawValue: parts[0]) else { return }
                appState.selectedAgentProvider = provider
                appState.selectedModel = parts[1]
            }
        )
    }

    private var selectedDefaultModel: AgentModel {
        appState.availableAgentModelSections()
            .flatMap(\.models)
            .first { $0.provider == appState.selectedAgentProvider && $0.id == appState.selectedModel }
            ?? AgentModel(
                provider: appState.selectedAgentProvider,
                id: appState.selectedModel,
                displayName: appState.modelDisplayLabel(appState.selectedModel, provider: appState.selectedAgentProvider),
                description: AppState.modelDescription(appState.selectedModel, provider: appState.selectedAgentProvider)
            )
    }

    // MARK: - Summarization Section

    private var summarizationSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Summarization Model")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used to generate short session titles. The default follows each thread's model.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $appState.summarizationProvider) {
                ForEach(SummarizationProvider.availableCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .popoverTip(RxCodeTips.SummarizationModelTip(), arrowEdge: .trailing)
            .onChange(of: appState.summarizationProvider) { _, newValue in
                guard newValue == .openAI, appState.openAISummarizationModels.isEmpty else { return }
                Task { await appState.refreshOpenAISummarizationModels() }
            }

            switch appState.summarizationProvider {
            case .selectedClient:
                Text("Uses the model saved on the current thread.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            case .openAI:
                openAISummarizationForm
            case .appleFoundationModel:
                appleFoundationModelStatus
            }
        }
    }

    private var appleFoundationModelStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs on-device with Apple Intelligence. Private, free, and offline.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
            if let reason = FoundationModelSummarizationService.unavailabilityReason {
                Text(reason)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openAISummarizationForm: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 10) {
            settingsTextFieldRow(
                label: "Endpoint",
                text: $appState.openAISummarizationEndpoint,
                prompt: AppState.defaultOpenAISummarizationEndpoint
            )

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("API Key")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                SecureField("sk-...", text: $appState.openAISummarizationAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            }

            HStack(spacing: 10) {
                Picker("Model", selection: $appState.openAISummarizationModel) {
                    if !appState.openAISummarizationModel.isEmpty,
                       !appState.openAISummarizationModels.contains(appState.openAISummarizationModel)
                    {
                        Text(appState.openAISummarizationModel).tag(appState.openAISummarizationModel)
                    }
                    ForEach(appState.openAISummarizationModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    if appState.openAISummarizationModels.isEmpty && appState.openAISummarizationModel.isEmpty {
                        Text("Fetch models first").tag("")
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)

                Button {
                    Task { await appState.refreshOpenAISummarizationModels() }
                } label: {
                    if appState.isLoadingOpenAISummarizationModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Fetch Models", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(appState.isLoadingOpenAISummarizationModels)
            }

            if let error = appState.openAISummarizationModelsError {
                Text(error)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard appState.openAISummarizationModels.isEmpty else { return }
            Task { await appState.refreshOpenAISummarizationModels() }
        }
    }

    private func settingsTextFieldRow(label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
        }
    }

    // MARK: - Permission Mode Section

    private var permissionModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Permission Mode")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the permission mode per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.permissionMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.displayName)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(AppState.permissionModeDescription(appState.permissionMode))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Effort Section

    private var effortSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Effort Level")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Used for new sessions. You can override the effort level per session from the toolbar.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Picker("", selection: $appState.selectedEffort) {
                Text("Auto").tag("auto")
                ForEach(AppState.availableEfforts, id: \.self) { effort in
                    Text(effortDisplayName(effort)).tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(AppState.effortDescription(appState.selectedEffort))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Focus Mode Section

    private var focusModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Focus Mode")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("focus.mode.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.focusMode) {
                Text("Enable Focus Mode")
            }
            .toggleStyle(.switch)
            .fixedSize()
        }
    }

    // MARK: - Auto-Preview Attachments Section

    private var autoPreviewSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Auto-preview Attachments")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("auto.preview.desc")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("URL links", isOn: $appState.autoPreviewSettings.url)
                Toggle("File paths", isOn: $appState.autoPreviewSettings.filePath)
                Toggle("Images", isOn: $appState.autoPreviewSettings.image)
                Toggle("Long text (200+ characters)", isOn: $appState.autoPreviewSettings.longText)
            }
            .toggleStyle(.checkbox)
        }
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
}

// MARK: - Memory Settings Section

struct MemorySettingsSection: View {
    @Environment(AppState.self) private var appState

    @State private var editingDraft: MemoryDraft?
    @State private var showMemoryBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            controlsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editingDraft) { draft in
            MemoryEditorSheet(draft: draft)
        }
        .sheet(isPresented: $showMemoryBrowser) {
            MemoryBrowserSheet()
                .environment(appState)
        }
    }

    private var controlsSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Memory")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Spacer()
                Button {
                    editingDraft = MemoryDraft()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add memory")
                Button {
                    showMemoryBrowser = true
                } label: {
                    Label("Manage", systemImage: "list.bullet.rectangle")
                }
                .help("View and manage saved memories")
            }

            Toggle(isOn: $appState.memoryEnabled) {
                Text("Enable Memory")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(isOn: $appState.memoryAutoCreateEnabled) {
                Text("Auto-create memories from completed chats")
            }
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!appState.memoryEnabled)

            Toggle(isOn: $appState.memoryInjectEnabled) {
                Text("Include relevant memories in agent context")
            }
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!appState.memoryEnabled)

            Stepper(value: $appState.memoryMaxContextItems, in: 1...12) {
                Text("Context memories: \(appState.memoryMaxContextItems)")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .fixedSize()
            .disabled(!appState.memoryEnabled || !appState.memoryInjectEnabled)

            Text("Saved memory history is available from Manage.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MemoryBrowserSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var items: [MemoryItem] = []
    @State private var isLoading = false
    @State private var editingDraft: MemoryDraft?
    @State private var deleteTarget: MemoryItem?
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Memory History")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                Spacer()
                Button {
                    editingDraft = MemoryDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                
                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete all memories")
                .disabled(items.isEmpty)
                Button("Done") { dismiss() }
            }

            searchSection

            ScrollView {
                memoryList
            }
        }
        .padding(20)
        .frame(width: 640, height: 540)
        .task { await refresh() }
        .onChange(of: appState.memoryRevision) { _, _ in
            Task { await refresh() }
        }
        .sheet(item: $editingDraft) { draft in
            MemoryEditorSheet(draft: draft) {
                Task { await refresh() }
            }
        }
        .alert("Delete Memory?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Task {
                        await appState.deleteMemoryItem(id: target.id)
                        deleteTarget = nil
                        await refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This memory will be removed from future agent context.")
        }
        .alert("Delete All Memories?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                Task {
                    await appState.deleteAllMemoryItems()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All saved memories will be removed. This action cannot be undone.")
        }
    }

    private var searchSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search memory", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await refresh() } }
            Button {
                Task { await refresh() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(isLoading)
        }
    }

    @ViewBuilder
    private var memoryList: some View {
        if items.isEmpty && !isLoading {
            VStack(alignment: .leading, spacing: 6) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No memories" : "No matching memories")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                Text("Saved memories are stored locally in SwiftData and embedded on-device.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    memoryRow(item)
                }
            }
        }
    }

    private func memoryRow(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.scope == "global" ? "globe" : "folder")
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.content)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(item.kind.capitalized)
                    Text(item.scope.capitalized)
                    if let projectId = item.projectId {
                        Text(projectName(for: projectId))
                    }
                    Text(item.updatedAt, style: .date)
                }
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                editingDraft = MemoryDraft(item: item)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit memory")

            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete memory")
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private func refresh() async {
        isLoading = true
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items = await appState.allMemoryItems()
        } else {
            items = await appState.searchMemoryItems(query: trimmed, limit: 100).map(\.item)
        }
        isLoading = false
    }

    private func projectName(for id: UUID) -> String {
        appState.projects.first(where: { $0.id == id })?.name ?? id.uuidString
    }
}

private struct MemoryDraft: Identifiable {
    let id = UUID()
    var existingId: String?
    var content: String
    var kind: String
    var scope: String
    var projectId: UUID?

    init() {
        self.existingId = nil
        self.content = ""
        self.kind = "fact"
        self.scope = "project"
        self.projectId = nil
    }

    init(item: MemoryItem) {
        self.existingId = item.id
        self.content = item.content
        self.kind = item.kind
        self.scope = item.scope
        self.projectId = item.projectId
    }
}

private struct MemoryEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MemoryDraft
    /// Invoked after a successful save so a presenting list can refresh.
    /// Deliberately argument-free: the draft is persisted here, inside the
    /// sheet, so the struct never crosses an escaping async closure boundary.
    private let onSaved: (() -> Void)?

    init(draft: MemoryDraft, onSaved: (() -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existingId == nil ? "Add Memory" : "Edit Memory")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))

            TextEditor(text: $draft.content)
                .font(.system(size: ClaudeTheme.size(12)))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )

            HStack(spacing: 12) {
                Picker("Kind", selection: $draft.kind) {
                    Text("Fact").tag("fact")
                    Text("Preference").tag("preference")
                    Text("Decision").tag("decision")
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Picker("Scope", selection: $draft.scope) {
                    Text("Project").tag("project")
                    Text("Global").tag("global")
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            if draft.scope == "project" {
                Picker("Project", selection: projectSelection) {
                    Text("No project").tag("")
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(project.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        await performSave()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Persists the draft directly through AppState. Kept inside the sheet —
    /// rather than handed back via a `(MemoryDraft) async -> Void` callback —
    /// so the struct is never passed through an escaping async closure.
    private func performSave() async {
        let draft = draft
        if let id = draft.existingId {
            _ = await appState.updateMemoryItem(
                id: id,
                content: draft.content,
                projectId: draft.projectId,
                kind: draft.kind,
                scope: draft.scope
            )
        } else {
            _ = await appState.addMemoryItem(
                content: draft.content,
                projectId: draft.projectId,
                kind: draft.kind,
                scope: draft.scope
            )
        }
        onSaved?()
    }

    private var projectSelection: Binding<String> {
        Binding(
            get: { draft.projectId?.uuidString ?? "" },
            set: { raw in draft.projectId = UUID(uuidString: raw) }
        )
    }
}

// MARK: - Theme Picker Row

private struct ThemePickerRow: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(theme.colors.accent)
                    .frame(width: 10, height: 10)
                Text(theme.displayName)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color(NSColor.selectedContentBackgroundColor).opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(WindowState())
}
