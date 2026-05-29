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
            pairingQRImage = makeOnboardingQRCode(from: qrString)
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

struct OnboardingSlide: Identifiable {
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

#Preview {
    OnboardingView()
        .environment(AppState())
}
