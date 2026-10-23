import RxAuthSwift
import RxCodeCore
import SwiftUI

private enum FlowcyTab: Hashable { case tasks, projects, settings, agent }

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(MobileCloudState.self) private var cloud
    @EnvironmentObject private var state: MobileAppState
    @State private var tools = FlowcyToolsState()
    @State private var agent = FlowcyAgentState()
    @AppStorage("flowcy.appearance") private var appearance = "system"
    @State private var selected: FlowcyTab = .tasks
    @State private var showingRemote = false
    @State private var showingPairing = false
    @State private var pairingCompleted = false
    @State private var showingTools = false

    var body: some View {
        Group {
            if UITestSupport.isActive && !ProcessInfo.processInfo.arguments.contains("-uitest-flowcy") {
                RemoteWorkspaceView()
            } else if cloud.isRestoring {
                MobileRestoringSessionView()
            } else if cloud.isSignedIn {
                if showingRemote { Color.clear } else { dashboard }
            } else {
                MobileSignInView()
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .environment(tools)
        .environment(agent)
        .task(id: cloud.accountID) {
            agent.restore(accountID: cloud.accountID)
            if cloud.isSignedIn {
                state.usesCloudTasks = true
                if state.pendingDeepLink != nil && state.isPaired { openRemote() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
            Task {
                // Legacy feature services also emit this after a service-specific 401.
                // Only end the account session when the identity token is unavailable.
                guard await cloud.auth.accessToken() == nil else { return }
                await cloud.signOut(requiresPushRemoval: false)
            }
        }
        .onChange(of: cloud.isSignedIn) { _, signedIn in
            if !signedIn {
                agent.cancel()
                agent.restore(accountID: nil)
                showingRemote = false
                showingPairing = false
                showingTools = false
                state.clearCloudTasks()
                Task { await tools.signOut() }
            }
        }
        .onChange(of: state.isPaired) { _, paired in
            if paired && cloud.isSignedIn && !showingPairing { openRemote() }
        }
        .onChange(of: state.pendingPermission?.id) { _, request in
            if request != nil && cloud.isSignedIn && state.isPaired { openRemote() }
        }
        .onChange(of: state.pendingDeepLink) { _, link in
            if link != nil && cloud.isSignedIn && state.isPaired { openRemote() }
        }
        .sheet(item: Binding(get: {
            cloud.isSignedIn && !showingRemote && !showingTools && !showingPairing ? cloud.pendingNotification : nil
        }, set: { if $0 == nil { cloud.pendingNotification = nil } })) { destination in
            FlowcyPushDestinationView(destination: destination, onOpenChat: { sessionID in
                cloud.pendingNotification = nil
                state.openThreadFromNotification(sessionID: sessionID, projectID: nil)
                openRemote()
            }).mobileSheetPresentation()
        }
        .onChange(of: cloud.pendingNotification) { _, destination in
            if destination != nil {
                selected = .settings
                showingTools = false
                showingPairing = false
                if showingRemote { state.usesCloudTasks = true; showingRemote = false }
            }
        }
        .sheet(isPresented: $showingTools) { FlowcyToolsView().environment(tools).mobileSheetPresentation() }
        .sheet(isPresented: $showingPairing) {
            NavigationStack {
                OnboardingView(showsCancelButton: true, onPairingCompleted: {
                    pairingCompleted = true
                    showingPairing = false
                })
                .navigationTitle("Connect New Remote")
            }
            .mobileSheetPresentation()
        }
        .onChange(of: showingPairing) { wasShowing, showing in
            if wasShowing && !showing && pairingCompleted { pairingCompleted = false; openRemote() }
        }
        .fullScreenCover(isPresented: $showingRemote, onDismiss: {
            state.usesCloudTasks = true
        }) {
            RemoteWorkspaceView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Button("Flowcy", systemImage: "chevron.left") {
                            MobileHaptics.buttonTap()
                            state.usesCloudTasks = true
                            showingRemote = false
                        }
                        Spacer()
                        Text(state.activePairedDesktop?.displayName ?? "Remote Workspace").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
        }
    }

    private var dashboard: some View {
        TabView(selection: $selected) {
            Tab("Tasks", systemImage: "checklist", value: FlowcyTab.tasks) {
                NavigationStack {
                    if !showingRemote {
                        MobileTasksDashboardView(onOpenChat: { _ in openRemote() })
                            .toolbar { FlowcyRemoteToolbar() }
                    }
                }
            }
            Tab("Projects", systemImage: "square.grid.2x2", value: FlowcyTab.projects) {
                FlowcyProjectsView()
            }
            Tab("Settings", systemImage: "gear", value: FlowcyTab.settings) {
                FlowcySettingsView()
            }
            if #available(iOS 27.0, *) {
                Tab("Agent", systemImage: "sparkles", value: FlowcyTab.agent, role: .prominent) { agentContent }
            } else {
                Tab("Agent", systemImage: "sparkles", value: FlowcyTab.agent) { agentContent }
            }
        }
        .environment(\.flowcyRemoteActions, FlowcyRemoteActions(connect: { showingPairing = true }, open: openRemote, showInSidebar: sizeClass == .compact))
        .onChange(of: selected) { _, _ in MobileHaptics.buttonTap() }
    }

    private var agentContent: some View {
        NavigationStack {
            FlowcyAgentView()
                .toolbar { FlowcyRemoteToolbar() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Flowcy Tools", systemImage: "wrench.and.screwdriver") {
                            MobileHaptics.buttonTap()
                            showingTools = true
                        }
                    }
                }
        }
    }

    private func openRemote() {
        guard state.isPaired else { showingPairing = true; return }
        state.usesCloudTasks = false
        showingRemote = true
    }
}

struct FlowcyRemoteActions {
    var connect: @MainActor () -> Void
    var open: @MainActor () -> Void
    var showInSidebar: Bool
}

extension EnvironmentValues {
    @Entry var flowcyRemoteActions: FlowcyRemoteActions?
}

/// Attach to navigation column content so SwiftUI keeps the menu when columns collapse.
struct FlowcyRemoteToolbar: ToolbarContent {
    var compactOnly = false
    @Environment(\.flowcyRemoteActions) private var actions
    @EnvironmentObject private var state: MobileAppState

    var body: some ToolbarContent {
        if let actions, !compactOnly || actions.showInSidebar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Connect New Remote", systemImage: "plus") {
                        MobileHaptics.buttonTap()
                        actions.connect()
                    }
                    ForEach(state.pairedDesktops) { desktop in
                        Button(desktop.displayName, systemImage: "desktopcomputer") {
                            MobileHaptics.buttonTap()
                            Task {
                                await state.switchPairedDesktop(desktop)
                                actions.open()
                            }
                        }
                    }
                } label: { Label("Remote Workspace", systemImage: "desktopcomputer") }
                .accessibilityIdentifier("flowcy-remote-menu")
            }
        }
    }
}

private enum FlowcySetting: String, CaseIterable, Identifiable {
    case integrations = "Integrations", automation = "Automation", billing = "Billing", account = "Account"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .integrations: "point.3.connected.trianglepath.dotted"
        case .automation: "bolt"
        case .billing: "creditcard"
        case .account: "person.crop.circle"
        }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .integrations: FlowcyIntegrationsView()
        case .billing: FlowcyBillingView()
        case .automation: MobileAutomationView()
        case .account: FlowcyAccountView()
        }
    }
}

private struct FlowcyIntegrationsView: View {
    var body: some View {
        List {
            NavigationLink { FlowcyNotificationsView() } label: {
                Label("Notifications", systemImage: "bell")
            }
            NavigationLink { FlowcyWebhooksView() } label: {
                Label("Webhooks", systemImage: "arrow.triangle.branch")
            }
            NavigationLink { MobileRepoSetupView() } label: {
                Label("Repository Setup", systemImage: "shippingbox")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FlowcySettingsView: View {
    @Environment(MobileCloudState.self) private var cloud
    @State private var selection: FlowcySetting?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: $selection) {
                Section("Features") {
                    ForEach(FlowcySetting.allCases.filter { $0 != .account }) { setting in
                        NavigationLink(value: setting) {
                            Label(setting.rawValue, systemImage: setting.symbol)
                        }
                        .listRowSeparator(.visible)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                Button {
                    selection = .account
                    preferredColumn = .detail
                    MobileHaptics.buttonTap()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cloud.auth.user?.email ?? "RxLab account")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("Account & General").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flowcy-settings-account")
                .padding()
            }
            .navigationTitle("Settings")
            .toolbar { FlowcyRemoteToolbar(compactOnly: true) }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
        } detail: {
            NavigationStack {
                Group {
                    if let selection {
                        selection.destination.id(selection)
                    } else {
                        ContentUnavailableView("Select a Setting", systemImage: "gear",
                                               description: Text("Choose a setting from the sidebar."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .toolbar { FlowcyRemoteToolbar() }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { _, _ in MobileHaptics.buttonTap() }
    }
}

private struct FlowcyAccountView: View {
    @Environment(MobileCloudState.self) private var cloud
    @AppStorage("flowcy.appearance") private var appearance = "system"
    @State private var confirmingSignOut = false
    @State private var signingOut = false
    @State private var signOutError: String?
    var body: some View {
        Form {
            Section("Signed In") {
                Label(cloud.auth.user?.email ?? "RxLab account", systemImage: "person.crop.circle")
                    .textSelection(.enabled)
            }
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, _ in MobileHaptics.buttonTap() }
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true; MobileHaptics.buttonTap() }
                    .disabled(signingOut)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of Flowcy?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                signingOut = true
                Task {
                    await cloud.signOut()
                    signingOut = false
                    if cloud.isSignedIn { signOutError = cloud.error; MobileHaptics.connectionError() }
                    else { MobileHaptics.connected() }
                }
            }
        }
        .alert("Could Not Sign Out", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button("OK") { signOutError = nil }
        } message: { Text(signOutError ?? "") }
        .overlay { if signingOut { ProgressView("Signing out…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }
}
