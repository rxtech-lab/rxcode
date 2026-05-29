import CoreImage.CIFilterBuiltins
import RxCodeCore
import RxCodeSync
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    var onCompletion: (() -> Void)? = nil

    @State private var selectedIndex = 0

    // CLI detection
    @State private var isCheckingCLI = false
    @State private var claudeInstalled = false
    @State private var claudeVersion: String?
    @State private var claudeError: String?
    @State private var codexInstalled = false
    @State private var codexVersion: String?
    @State private var codexError: String?

    // ACP install
    @State private var installingAgentId: String?
    @State private var acpError: String?

    // Summarization
    @State private var summarizationEndpointDraft: String = ""
    @State private var summarizationAPIKeyDraft: String = ""
    @State private var hasLoadedSummarizationModels = false

    // Mobile pairing
    @State private var pairingToken: PairingToken?
    @State private var pairingQRImage: NSImage?
    @State private var pairingError: String?
    @State private var downloadLinks: DownloadLinks?
    @State private var isLoadingDownloads = false
    @State private var pairingReloadTask: Task<Void, Never>?
    @State private var selectedRelayServerID: UUID?
    @State private var showAddRelayServerSheet = false
    @State private var relayPresetCatalog = RelayPresetCatalog.shared
    @StateObject private var mobileSync = MobileSyncService.shared

    // MCP setup
    @State private var mcpSpec = MCPServerSpec()
    @State private var mcpArgsText = ""
    @State private var mcpError: String?
    @State private var mcpSaving = false
    @State private var mcpAdded = false

    private let slides = OnboardingSlide.all

    private var isFirstSlide: Bool {
        selectedIndex == 0
    }

    private var isLastSlide: Bool {
        selectedIndex == slides.count - 1
    }

    private var currentSlide: OnboardingSlide {
        slides[selectedIndex]
    }

    private var canContinue: Bool {
        switch currentSlide.visual {
        case .cliSetup:
            return claudeInstalled || codexInstalled
        default:
            return true
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - 72, 820)

            ZStack {
                onboardingBackdrop

                slideCard
                    .frame(width: contentWidth, height: min(proxy.size.height - 68, 660))
                    .padding(.vertical, 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 700, idealHeight: 760)
        .background(ClaudeTheme.background)
        .task {
            await checkCLI()
            await loadDownloadLinks()
            await relayPresetCatalog.refresh()
            summarizationEndpointDraft = appState.openAISummarizationEndpoint
            summarizationAPIKeyDraft = appState.openAISummarizationAPIKey
            if selectedRelayServerID == nil {
                selectedRelayServerID = mobileSync.savedRelayServers.first?.id
            }
        }
        .sheet(isPresented: $showAddRelayServerSheet, onDismiss: {
            if selectedRelayServerID == nil || !mobileSync.savedRelayServers.contains(where: { $0.id == selectedRelayServerID }) {
                selectedRelayServerID = mobileSync.savedRelayServers.last?.id
            }
            startPairing()
        }) {
            RelayServerEditorSheet(sync: mobileSync, catalog: relayPresetCatalog, existingServer: nil)
        }
        .onDisappear {
            pairingReloadTask?.cancel()
            pairingReloadTask = nil
            // Don't leave a partial pairing token alive once the user leaves
            // onboarding without finishing.
            if MobileSyncService.shared.pendingPairing == nil {
                MobileSyncService.shared.cancelPairing()
            }
        }
    }

    private var onboardingBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    ClaudeTheme.background,
                    ClaudeTheme.surfaceSecondary.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                ClaudeTheme.accent.opacity(0.22),
                                ClaudeTheme.surfacePrimary.opacity(0.08),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 260)
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    private var slideCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ClaudeTheme.surfaceElevated,
                            ClaudeTheme.surfacePrimary,
                            ClaudeTheme.background.opacity(0.96)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 28, y: 18)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)

            ZStack {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    slideContent(slide)
                        .opacity(selectedIndex == index ? 1 : 0)
                        .scaleEffect(selectedIndex == index ? 1 : 0.96)
                        .offset(x: CGFloat(index - selectedIndex) * 72)
                        .allowsHitTesting(selectedIndex == index)
                }
            }
            .animation(.snappy(duration: 0.46), value: selectedIndex)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func slideContent(_ slide: OnboardingSlide) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                slideVisual(slide.visual)
                    .padding(.horizontal, 42)
                    .padding(.top, 36)
                    .padding(.bottom, 22)

                HStack {
                    circularNavigationButton(systemImage: "chevron.left") {
                        goBack()
                    }
                    .opacity(isFirstSlide ? 0.26 : 1)
                    .disabled(isFirstSlide)

                    Spacer()

                    circularNavigationButton(systemImage: isLastSlide ? "checkmark" : "chevron.right") {
                        advance()
                    }
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.38)
                }
                .padding(20)
            }

            pageIndicator
                .padding(.bottom, 24)

            VStack(spacing: 9) {
                Text(slide.title)
                    .font(.system(size: ClaudeTheme.size(28), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(slide.subtitle)
                    .font(.system(size: ClaudeTheme.size(15)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }
            .padding(.horizontal, 48)

            Spacer(minLength: 18)

            Button {
                advance()
            } label: {
                Text(isLastSlide ? LocalizedStringKey("Get Started") : LocalizedStringKey("Continue"))
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .frame(width: 230, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(canContinue ? ClaudeTheme.accent : ClaudeTheme.textTertiary, in: Capsule())
            .shadow(color: ClaudeTheme.accent.opacity(canContinue ? 0.24 : 0), radius: 12, y: 6)
            .disabled(!canContinue)
            .padding(.bottom, 34)
        }
    }

    @ViewBuilder
    private func slideVisual(_ visual: OnboardingSlide.Visual) -> some View {
        switch visual {
        case .workspace:
            WorkspacePreview()
        case .approvals:
            ApprovalPreview()
        case .cliSetup:
            CLISetupPreview(
                isCheckingCLI: isCheckingCLI,
                claudeInstalled: claudeInstalled,
                claudeVersion: claudeVersion,
                claudeError: claudeError,
                codexInstalled: codexInstalled,
                codexVersion: codexVersion,
                codexError: codexError,
                onCheckAgain: { Task { await checkCLI() } }
            )
        case .acpSetup:
            ACPSetupPreview(
                appState: appState,
                installingAgentId: $installingAgentId,
                errorMessage: $acpError
            )
        case .summarizationModel:
            SummarizationSetupPreview(
                appState: appState,
                endpointDraft: $summarizationEndpointDraft,
                apiKeyDraft: $summarizationAPIKeyDraft,
                hasLoadedModels: $hasLoadedSummarizationModels
            )
        case .mobilePairing:
            MobilePairingPreview(
                token: pairingToken,
                qrImage: pairingQRImage,
                downloadLinks: downloadLinks,
                isLoadingDownloads: isLoadingDownloads,
                errorMessage: pairingError,
                savedRelayServers: mobileSync.savedRelayServers,
                selectedRelayServerID: $selectedRelayServerID,
                onRegenerate: { startPairing() },
                onAddRelayServer: { showAddRelayServerSheet = true }
            )
            .onAppear { startPairing() }
            .onChange(of: selectedRelayServerID) { _, _ in
                startPairing()
            }
            .onDisappear {
                pairingReloadTask?.cancel()
                pairingReloadTask = nil
            }
        case .mcpSetup:
            MCPSetupPreview(
                spec: $mcpSpec,
                argsText: $mcpArgsText,
                isSaving: $mcpSaving,
                added: $mcpAdded,
                errorMessage: $mcpError,
                onSave: { await saveMCPServer() }
            )
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(slides.indices, id: \.self) { index in
                Capsule()
                    .fill(index == selectedIndex ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary.opacity(0.36))
                    .frame(width: index == selectedIndex ? 24 : 8, height: 8)
                    .animation(.snappy(duration: 0.28), value: selectedIndex)
            }
        }
        .accessibilityHidden(true)
    }

    private func circularNavigationButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(17), weight: .semibold))
                .frame(width: 42, height: 42)
                .foregroundStyle(.white)
                .background(.white.opacity(0.18), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(systemImage == "chevron.left" ? LocalizedStringKey("Back") : LocalizedStringKey("Continue"))
    }

    private func goBack() {
        guard selectedIndex > 0 else { return }
        withAnimation(.snappy(duration: 0.42)) {
            selectedIndex -= 1
        }
    }

    private func advance(skipping: Bool = false) {
        guard skipping || canContinue else { return }

        if isLastSlide {
            completeOnboarding()
        } else {
            withAnimation(.snappy(duration: 0.42)) {
                selectedIndex += 1
            }
        }
    }

    private func completeOnboarding() {
        // Persist any draft fields the user typed on summarization slide.
        if summarizationEndpointDraft != appState.openAISummarizationEndpoint {
            appState.openAISummarizationEndpoint = summarizationEndpointDraft
        }
        if summarizationAPIKeyDraft != appState.openAISummarizationAPIKey {
            appState.openAISummarizationAPIKey = summarizationAPIKeyDraft
        }
        appState.onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onCompletion?()
    }

    // MARK: - CLI

    private func checkCLI() async {
        isCheckingCLI = true
        claudeError = nil
        codexError = nil

        do {
            let version = try await appState.claude.checkVersion()
            claudeVersion = version
            claudeInstalled = true
            appState.claudeInstalled = true
            appState.claudeVersion = version
            appState.claudeBinaryPath = await appState.claude.findClaudeBinary()
        } catch {
            claudeInstalled = false
            claudeVersion = nil
            claudeError = error.localizedDescription

            let binary = await appState.claude.findClaudeBinary()
            appState.claudeBinaryPath = binary
            if let binary {
                claudeError = String(localized: "Binary found: \(binary), but version check failed")
                claudeInstalled = true
                appState.claudeInstalled = true
                appState.claudeVersion = nil
            } else {
                appState.claudeInstalled = false
                appState.claudeVersion = nil
            }
        }

        do {
            let version = try await appState.codex.checkVersion()
            codexVersion = version
            codexInstalled = true
            appState.codexInstalled = true
            appState.codexVersion = version
            appState.codexBinaryPath = await appState.codex.findCodexBinary()
        } catch {
            codexInstalled = false
            codexVersion = nil
            codexError = error.localizedDescription

            let binary = await appState.codex.findCodexBinary()
            appState.codexBinaryPath = binary
            if let binary {
                codexError = String(localized: "Binary found: \(binary), but version check failed")
                codexInstalled = true
                appState.codexInstalled = true
                appState.codexVersion = nil
            } else {
                appState.codexInstalled = false
                appState.codexVersion = nil
            }
        }

        isCheckingCLI = false
    }

    // MARK: - Mobile pairing

    private func startPairing() {
        pairingReloadTask?.cancel()
        let sync = MobileSyncService.shared
        guard !sync.savedRelayServers.isEmpty else {
            pairingToken = nil
            pairingQRImage = nil
            pairingError = String(localized: "Add a relay server to pair your phone.")
            return
        }
        let server = selectedRelayServerID.flatMap { id in
            sync.savedRelayServers.first { $0.id == id }
        }
        guard let fresh = sync.beginPairing(viaServer: server) else {
            pairingToken = nil
            pairingQRImage = nil
            pairingError = String(localized: "Could not start pairing. Pick a different relay server or add a new one.")
            return
        }
        pairingToken = fresh
        pairingQRImage = nil
        pairingError = nil
        if let qrString = try? fresh.qrString() {
            pairingQRImage = makeQRCode(from: qrString)
        }
        scheduleAutoReload(for: fresh)
    }

    private func scheduleAutoReload(for token: PairingToken) {
        pairingReloadTask = Task { @MainActor in
            let delay = max(0, token.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard MobileSyncService.shared.pendingPairing == nil else { return }
            startPairing()
        }
    }

    private func loadDownloadLinks() async {
        isLoadingDownloads = true
        defer { isLoadingDownloads = false }
        downloadLinks = await DownloadLinks.fetch()
    }

    // MARK: - MCP

    private func saveMCPServer() async {
        mcpError = nil
        mcpSaving = true
        defer { mcpSaving = false }
        let spec = mcpSpec
        if let err = await appState.addMCPServer(spec: spec, scope: .user) {
            mcpError = err
            return
        }
        mcpAdded = true
    }
}

// MARK: - Slide model

private struct OnboardingSlide: Identifiable {
    enum Visual {
        case workspace
        case approvals
        case cliSetup
        case acpSetup
        case summarizationModel
        case mobilePairing
        case mcpSetup
    }

    let id: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let visual: Visual
    let canSkip: Bool

    static let all: [OnboardingSlide] = [
        OnboardingSlide(
            id: "workspace",
            title: "Work with coding agents in one native app",
            subtitle: "Open projects, switch threads, and keep agent conversations close to the files they change.",
            visual: .workspace,
            canSkip: false
        ),
        OnboardingSlide(
            id: "approvals",
            title: "Approve risky actions with context",
            subtitle: "Review commands, diffs, and permission requests before an agent changes your workspace.",
            visual: .approvals,
            canSkip: false
        ),
        OnboardingSlide(
            id: "cli",
            title: "Connect at least one agent CLI",
            subtitle: "RxCode runs Claude Code or Codex locally. Install one of them to start your first project.",
            visual: .cliSetup,
            canSkip: false
        ),
        OnboardingSlide(
            id: "acp",
            title: "Add an Agent Client Protocol client",
            subtitle: "Install additional coding agents from the ACP registry. You can skip this and add clients later.",
            visual: .acpSetup,
            canSkip: true
        ),
        OnboardingSlide(
            id: "summarization",
            title: "Pick a summarization model",
            subtitle: "Used for thread titles, branch briefings, and search. Defaults to your chat model.",
            visual: .summarizationModel,
            canSkip: true
        ),
        OnboardingSlide(
            id: "mobile",
            title: "Pair your phone",
            subtitle: "Follow active threads, approve permissions, and pick up work from your iPhone, iPad, or Android device.",
            visual: .mobilePairing,
            canSkip: true
        ),
        OnboardingSlide(
            id: "mcp",
            title: "Set up your first MCP server",
            subtitle: "Model Context Protocol servers expose tools and resources to every agent. Optional — you can skip this step.",
            visual: .mcpSetup,
            canSkip: true
        )
    ]
}

// MARK: - Existing previews (workspace, approvals)

private struct WorkspacePreview: View {
    var body: some View {
        OnboardingMockWindow(title: "RxCode") {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    PreviewSidebarRow(icon: "folder", title: LocalizedStringKey("Projects"), isActive: true)
                    PreviewSidebarRow(icon: "clock", title: LocalizedStringKey("Threads"), isActive: false)
                    PreviewSidebarRow(icon: "doc.text", title: LocalizedStringKey("Briefing"), isActive: false)
                    Spacer()
                }
                .frame(width: 148)
                .padding(14)
                .background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 12) {
                    PreviewBubble(title: LocalizedStringKey("Refactor onboarding into slides"), isUser: true)
                    PreviewToolRow(icon: "terminal", title: LocalizedStringKey("Running swift build"), accent: ClaudeTheme.statusRunning)
                    PreviewBubble(title: LocalizedStringKey("I found the existing onboarding view and will keep the CLI check as setup."), isUser: false)
                    Spacer()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 620)
    }
}

private struct ApprovalPreview: View {
    var body: some View {
        OnboardingMockWindow(title: LocalizedStringKey("Permission Request")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Review Command")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("The agent wants to run a command in this project.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }

                Text(verbatim: "xcodebuild -project RxCode.xcodeproj -scheme RxCode build")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    PreviewActionButton(title: LocalizedStringKey("Deny"), fill: Color.white.opacity(0.12))
                    PreviewActionButton(title: LocalizedStringKey("Allow"), fill: ClaudeTheme.accent)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: 540)
    }
}

// MARK: - CLI setup

private struct CLISetupPreview: View {
    let isCheckingCLI: Bool
    let claudeInstalled: Bool
    let claudeVersion: String?
    let claudeError: String?
    let codexInstalled: Bool
    let codexVersion: String?
    let codexError: String?
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Agent CLI Setup")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if isCheckingCLI {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(spacing: 10) {
                CLIStatusRow(
                    title: "Claude Code",
                    installed: claudeInstalled,
                    version: claudeVersion,
                    error: claudeError,
                    installCommand: "npm install -g @anthropic-ai/claude-code"
                )
                CLIStatusRow(
                    title: "Codex",
                    installed: codexInstalled,
                    version: codexVersion,
                    error: codexError,
                    installCommand: "npm install -g @openai/codex"
                )
            }

            HStack {
                Text(claudeInstalled || codexInstalled ? LocalizedStringKey("Ready to start.") : LocalizedStringKey("Install one CLI, then check again."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Button {
                    onCheckAgain()
                } label: {
                    Text("Check Again")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .disabled(isCheckingCLI)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct CLIStatusRow: View {
    let title: String
    let installed: Bool
    let version: String?
    let error: String?
    let installCommand: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(installed ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                Text(verbatim: installed
                     ? "\(title) \(String(localized: "installed"))\(version.map { " - \($0)" } ?? "")"
                     : "\(title) \(String(localized: "not found"))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }

            if !installed {
                if let error {
                    Text(verbatim: error)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(verbatim: installCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help(LocalizedStringKey("Copy install command"))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - ACP setup

private struct ACPSetupPreview: View {
    let appState: AppState
    @Binding var installingAgentId: String?
    @Binding var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("ACP Clients")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if appState.acpRegistryLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await appState.refreshACPRegistry(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey("Refresh registry"))
                }
            }

            Text("Install additional ACP-compatible agents — RxCode downloads the right binary for macOS and probes the model list.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))

            ScrollView {
                VStack(spacing: 8) {
                    if let agents = appState.acpRegistry?.agents, !agents.isEmpty {
                        ForEach(agents.prefix(6)) { agent in
                            registryRow(agent)
                        }
                    } else if appState.acpRegistryLoading {
                        Text("Loading registry…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.54))
                    } else {
                        Text("Could not load registry. Check your network connection.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                }
            }
            .frame(maxHeight: 170)

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .task {
            if appState.acpRegistry == nil && !appState.acpRegistryLoading {
                await appState.refreshACPRegistry()
            }
        }
    }

    private func registryRow(_ agent: ACPRegistryAgent) -> some View {
        let alreadyInstalled = appState.acpClients.contains { $0.registryId == agent.id }
        let isInstalling = installingAgentId == agent.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: "v\(agent.version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(verbatim: agent.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Group {
                if alreadyInstalled {
                    Text("Installed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                } else if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        install(agent)
                    } label: {
                        Text("Add")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 56, height: 24)
                            .foregroundStyle(.white)
                            .background(ClaudeTheme.accent.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(installingAgentId != nil)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func install(_ agent: ACPRegistryAgent) {
        installingAgentId = agent.id
        errorMessage = nil
        Task {
            defer { installingAgentId = nil }
            do {
                let spec = try await appState.installACPClient(from: agent)
                appState.addACPClient(spec)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Summarization

private struct SummarizationSetupPreview: View {
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
                    .foregroundStyle(.white)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Provider")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Picker("", selection: $appState.summarizationProvider) {
                    ForEach(SummarizationProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            switch appState.summarizationProvider {
            case .selectedClient:
                Text("Uses the model picked by the current thread. No extra configuration needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            case .appleFoundationModel:
                Text("Runs on-device using Apple Intelligence. Free, private, and offline.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            case .openAI:
                openAISection
            }
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(ClaudeTheme.accent.opacity(0.85), in: Capsule())
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
                .foregroundStyle(.white.opacity(0.62))
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
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 78, alignment: .leading)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Mobile pairing

private struct MobilePairingPreview: View {
    let token: PairingToken?
    let qrImage: NSImage?
    let downloadLinks: DownloadLinks?
    let isLoadingDownloads: Bool
    let errorMessage: String?
    let savedRelayServers: [SavedRelayServer]
    @Binding var selectedRelayServerID: UUID?
    let onRegenerate: () -> Void
    let onAddRelayServer: () -> Void

    private var hasDownloadOptions: Bool {
        guard let links = downloadLinks else { return false }
        let urls = [
            links.ios.appStoreURL,
            links.android.playStoreURL,
            links.android.apkURL
        ]
        return urls.contains { !$0.isEmpty }
    }

    private var showDownloadPanel: Bool {
        isLoadingDownloads || hasDownloadOptions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            pairingPanel
            if showDownloadPanel {
                downloadPanel
            }
        }
        .frame(maxWidth: 640)
    }

    private var pairingPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Pair via QR")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            relaySelector

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .background(Color.white.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let errorMessage {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    Text(verbatim: errorMessage)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: 180, height: 180)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ProgressView()
                    .frame(width: 180, height: 180)
            }

            if let token {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = Int(token.expiresAt.timeIntervalSince(context.date).rounded(.down))
                    Text(remaining > 0
                         ? String(format: NSLocalizedString("Expires in %d:%02d", comment: ""), remaining / 60, remaining % 60)
                         : String(localized: "Expired"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Button {
                onRegenerate()
            } label: {
                Label(LocalizedStringKey("Regenerate"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var relaySelector: some View {
        if savedRelayServers.isEmpty {
            VStack(spacing: 8) {
                Text("No relay server configured")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button {
                    onAddRelayServer()
                } label: {
                    Label(LocalizedStringKey("Add Relay Server"), systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ClaudeTheme.accent.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 6) {
                Text("Relay")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Picker("", selection: $selectedRelayServerID) {
                    ForEach(savedRelayServers) { server in
                        Text(verbatim: server.name).tag(Optional(server.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Button {
                    onAddRelayServer()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.white)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("Add Relay Server"))
            }
        }
    }

    private var downloadPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Install the app")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            Text("Open RxCode on your phone, then tap Pair Device and scan the QR code.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))

            if isLoadingDownloads {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if let links = downloadLinks {
                downloadButtons(links: links)
            } else {
                Text("Download links unavailable. Visit rxlab.app to install the mobile app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func downloadButtons(links: DownloadLinks) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = URL(string: links.ios.appStoreURL), !links.ios.appStoreURL.isEmpty {
                downloadLinkButton(
                    icon: "applelogo",
                    label: LocalizedStringKey("Download for iOS"),
                    sublabel: links.ios.version,
                    url: url
                )
            }
            if let url = URL(string: links.android.playStoreURL), !links.android.playStoreURL.isEmpty {
                downloadLinkButton(
                    icon: "smartphone",
                    label: LocalizedStringKey("Get it on Google Play"),
                    sublabel: links.android.version,
                    url: url
                )
            }
            if let url = URL(string: links.android.apkURL), !links.android.apkURL.isEmpty {
                downloadLinkButton(
                    icon: "arrow.down.circle",
                    label: LocalizedStringKey("Download APK"),
                    sublabel: links.android.version,
                    url: url
                )
            }
        }
    }

    private func downloadLinkButton(icon: String, label: LocalizedStringKey, sublabel: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                    if !sublabel.isEmpty {
                        Text(verbatim: sublabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MCP setup

private struct MCPSetupPreview: View {
    @Binding var spec: MCPServerSpec
    @Binding var argsText: String
    @Binding var isSaving: Bool
    @Binding var added: Bool
    @Binding var errorMessage: String?
    let onSave: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("First MCP Server")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if added {
                    Label(LocalizedStringKey("Added"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                }
            }

            Text("Connect any MCP server to give every agent extra tools. You can also skip this and add servers later in Settings → MCP.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))

            field(label: LocalizedStringKey("Name"), placeholder: "my-server", text: $spec.name)

            HStack(spacing: 8) {
                Text("Transport")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 78, alignment: .leading)
                Picker("", selection: $spec.transport) {
                    ForEach(MCPTransport.allCases) { t in
                        Text(verbatim: t.displayNameText).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if spec.transport == .stdio {
                field(label: LocalizedStringKey("Command"), placeholder: "npx", text: $spec.command)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Args (one per line)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    TextEditor(text: $argsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 48, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                        .onChange(of: argsText) { _, newValue in
                            spec.args = newValue
                                .split(whereSeparator: \.isNewline)
                                .map { String($0).trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                }
            } else {
                field(label: LocalizedStringKey("URL"), placeholder: "https://example.com/mcp", text: $spec.url)
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button {
                    Task { await onSave() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(added ? LocalizedStringKey("Saved") : LocalizedStringKey("Save Server"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background((canSave ? ClaudeTheme.accent : ClaudeTheme.textTertiary).opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isSaving || added)
            }
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var canSave: Bool {
        guard !spec.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch spec.transport {
        case .stdio:
            return !spec.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return URL(string: spec.url) != nil && !spec.url.isEmpty
        }
    }

    private func field(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 78, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Download links model

struct DownloadLinks: Decodable, Sendable {
    struct IOS: Decodable, Sendable {
        let appStoreURL: String
        let testflightURL: String
        let version: String
    }
    struct Android: Decodable, Sendable {
        let playStoreURL: String
        let apkURL: String
        let version: String
    }
    let ios: IOS
    let android: Android

    private static let endpoint = URL(string: "https://rxlab.app/api/download")!

    static func fetch() async -> DownloadLinks? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 6
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(DownloadLinks.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - QR code helper

private func makeQRCode(from string: String) -> NSImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
}

// MARK: - Shared layout primitives

private struct OnboardingMockWindow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = LocalizedStringKey(title)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red.opacity(0.82)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.82)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.82)).frame(width: 10, height: 10)
                Spacer()
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.black.opacity(0.32))

            content
                .frame(height: 268)
                .background(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x171A23),
                            Color(hex: 0x202536),
                            Color(hex: 0x11131A)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 14)
    }
}

private struct PreviewSidebarRow: View {
    let icon: String
    let title: LocalizedStringKey
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .foregroundStyle(isActive ? .white : .white.opacity(0.58))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isActive ? ClaudeTheme.accent.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PreviewBubble: View {
    let title: LocalizedStringKey
    let isUser: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: isUser ? 250 : 340, alignment: .leading)
            .background(isUser ? ClaudeTheme.accent.opacity(0.72) : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct PreviewToolRow: View {
    let icon: String
    let title: LocalizedStringKey
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PreviewActionButton: View {
    let title: LocalizedStringKey
    let fill: Color

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}
