import SwiftUI
import RxCodeCore
import RxCodeChatKit

struct UsageIntegrationEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var integration: UsageIntegration
    @State private var credential = ""
    @State private var oauth = UsageOAuthConfiguration()
    @State private var busy = false
    @State private var error: String?
    @State private var signedIn = false
    @State private var signingIn = false
    @State private var signInTask: Task<Void, Never>?
    @State private var signIn = UsageOAuthSignIn()
    @State private var cloudflareScope = CloudflareUsageScope.account
    @State private var cloudflareResource = ""
    @State private var vercelAccounts: [VercelAccount] = []
    @State private var loadingAccounts = false
    @State private var gatewayCredential = ""
    @State private var billingCredential = ""
    @State private var hasBillingCredential = false
    @State private var accountsError: String?
    @State private var cloudflareAccounts: [CloudflareAccount] = []
    @State private var accountRefreshID = UUID()
    private var acp: Bool { integration.pluginID.hasPrefix("acp-") }
    private var local: Bool { integration.pluginID.hasPrefix("ai-") || acp }
    private var compatibleACPClients: [ACPClientSpec] {
        appState.acpClients.filter { ACPUsageProvider.provider(for: $0)?.pluginID == integration.pluginID }
    }
    private var usesOAuth: Bool { ["vercel", "cloudflare"].contains(integration.pluginID) }
    private var vercel: Bool { integration.pluginID == "vercel" }
    /// Vercel OAuth is hidden (see `VercelUsageOAuth.isEnabled`); Vercel uses an access token instead.
    private var vercelOAuth: Bool { vercel && VercelUsageOAuth.isEnabled }
    var body: some View {
        NavigationStack {
            Form {
                Section("Integration") {
                    Picker("Integration", selection: $integration.pluginID) {
                        ForEach(AppState.usagePluginIDs, id: \.self) { Text(providerName($0)).tag($0) }
                    }.disabled(existing)
                    TextField("Name", text: $integration.title)
                    Picker("RxCode project", selection: $integration.projectID) {
                        Text("All projects").tag(UUID?.none)
                        ForEach(appState.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if local { localSection }
                if vercel {
                    vercelSection
                    Section("AI Gateway credits") {
                        SecureField("AI Gateway API key (leave blank to keep existing key)", text: $gatewayCredential)
                        Text("Use an AI Gateway key from the selected Vercel team. Shows the team's remaining USD balance, even when billable usage is filtered by project. Stored only in Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if !local {
                    accountSection
                    scopeSection
                    if integration.pluginID == "cloudflare" && cloudflareScope == .account { cloudflareBillingSection }
                }
            }.formStyle(.grouped)
            .disabled(busy)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(existing ? "Edit usage integration" : "Add usage integration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if signingIn { signInTask?.cancel() } else { dismiss() } }.disabled(busy && !signingIn)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy || integration.title.isEmpty || (acp && !compatibleACPClients.contains(where: { $0.id == integration.resource })) || (!local && !vercel && integration.account.isEmpty) || (integration.pluginID == "cloudflare" && cloudflareScope != .account && cloudflareResource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 540, maxHeight: .infinity)
        .interactiveDismissDisabled(busy)
        .task(id: "\(integration.pluginID):\(signedIn):\(accountRefreshID)") {
            if integration.pluginID == "cloudflare" && signedIn { await loadCloudflareAccounts() }
        }
        .onChange(of: integration.pluginID) { _, _ in
            integration.account = ""
            integration.resource = ""
            credential = ""
            gatewayCredential = ""
            billingCredential = ""
            hasBillingCredential = false
            oauth = integration.pluginID == "cloudflare" ? CloudflareUsageOAuth.configuration(nil) : .init()
            signedIn = false
            cloudflareScope = .account
            cloudflareResource = ""
            vercelAccounts = []
            cloudflareAccounts = []
            accountsError = nil
        }
        .onAppear {
            oauth = integration.resolvedOAuth ?? .init()
            signedIn = UsageOAuthTokens.hasTokens(integration.id)
            cloudflareScope = .init(resource: integration.resource)
            cloudflareResource = cloudflareScope.name(in: integration.resource)
            if vercel && (signedIn || !VercelUsageOAuth.isEnabled) { loadVercelAccounts() }
        }
        .task(id: integration.id) {
            hasBillingCredential = !(await UsageDashboardStore.shared.billingCredential(for: integration.id) ?? "").isEmpty
        }
        .overlay { if busy { ProgressView(signingIn ? "Waiting for browser sign-in…" : "Updating integration…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("Integration could not be updated", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private var existing: Bool {
        appState.usageDashboard.integrations.contains { $0.id == integration.id }
    }

    private func providerName(_ id: String) -> String {
        switch id {
        case "vercel": "Vercel"
        case "neon": "Neon"
        case "turso": "Turso"
        case "cloudflare": "Cloudflare"
        case "github-ci": "GitHub CI"
        case "ai-usage": "AI usage"
        case "ai-limits": "AI limits"
        case "acp-opencode": "OpenCode"
        case "acp-antigravity": "Antigravity"
        default: id
        }
    }

    private var localSection: some View {
        Section("Account") {
            if acp {
                Picker("Installed ACP client", selection: $integration.resource) {
                    Text("Choose a client").tag("")
                    ForEach(compatibleACPClients) { Text($0.displayName).tag($0.id) }
                }
                Text(integration.pluginID == "acp-opencode"
                     ? "Reads OpenCode Go usage limits using this client's existing login or OPENCODE_API_KEY. Other providers and prepaid balances are not reported."
                     : "Reads Antigravity quota windows using the agy login in macOS Keychain. Open Antigravity or agy to refresh an expired login.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Uses existing agent connections", systemImage: "person.crop.circle")
                Text("Usage is read from the agent connections already configured in RxCode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            if usesOAuth {
                if signedIn {
                    Label("Signed in with \(providerName(integration.pluginID))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                signInButton
                Text("Sign-in opens your browser and returns to RxCode. Credentials are stored only in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField("API key (leave blank to keep existing key)", text: $credential)
                Text("Use a \(providerName(integration.pluginID)) API key with read access to the selected scope. Stored only in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var scopeSection: some View {
        switch integration.pluginID {
        case "cloudflare":
            Section("Usage scope") {
                cloudflareAccountPicker
                Picker("Usage scope", selection: $cloudflareScope) {
                    ForEach(CloudflareUsageScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if cloudflareScope != .account {
                    TextField(cloudflareScope == .zone ? "Zone ID" : (cloudflareScope == .worker ? "Worker script name" : "Bucket name (include jurisdiction prefix if applicable)"), text: $cloudflareResource)
                }
                Text(cloudflareScope == .worker || cloudflareScope == .r2
                     ? "Shows the last 24 hours of resource analytics, not billed cost. R2 storage uses the latest sample. Grant Account Analytics read access."
                     : "Shows metered consumption for the current billing period, not an invoice total. Worker script and R2 bucket scopes use resource analytics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case "github-ci":
            Section("Repositories") {
                TextField("Repositories (owner/repo, comma separated)", text: $integration.account)
                Text("Enter the repositories whose workflow queue times you want to monitor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        default:
            Section("Organization") {
                TextField(integration.pluginID == "turso" ? "Organization name" : "Organization ID", text: $integration.account)
                TextField(integration.pluginID == "turso" ? "Database name (optional)" : "Provider project ID (optional)", text: $integration.resource)
                Text(integration.pluginID == "turso"
                     ? "Leave the database blank for organization usage in the current billing period, or enter a database for its usage over the last 30 days."
                     : "Shows consumption over the last 30 days. Leave the project blank to include all projects in the organization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var signInButton: some View {
        Button(signedIn ? "Sign in again" : "Sign in with \(integration.pluginID.capitalized)") {
            busy = true; signingIn = true
            if integration.pluginID != "vercel" { integration.oauth = oauth }
            signInTask = Task {
                defer { busy = false; signingIn = false; signInTask = nil }
                do {
                    try await signIn.signIn(integration); signedIn = true
                    if vercel { loadVercelAccounts() }
                    if integration.pluginID == "cloudflare" { accountRefreshID = UUID() }
                }
                catch is CancellationError {}
                catch { self.error = error.localizedDescription }
            }
        }.disabled(busy || (integration.pluginID != "vercel" && oauth.clientID.isEmpty))
    }
    /// Authenticate with a Vercel access token (or OAuth when re-enabled), then pick the billed team
    /// (or type it when the token can't list teams).
    @ViewBuilder private var vercelSection: some View {
        Section("Account") {
            if vercelOAuth {
                if signedIn {
                    Label("Signed in with Vercel", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                signInButton
                Text("Sign-in opens your browser and returns to RxCode through a local callback on port \(String(VercelUsageOAuth.callbackPort)).").font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField("Access token (leave blank to keep existing token)", text: $credential)
                    .onSubmit { loadVercelAccounts() }
                MarkdownContentView(text: "Create an access token at [vercel.com/account/settings/tokens](https://vercel.com/account/settings/tokens), scoped to the team whose usage you want to see.", style: .rxCodeCompact)
            }
        }
        Section("Team") {
            HStack {
                if vercelAccounts.isEmpty {
                    TextField("Team ID or slug (blank for default team)", text: $integration.account)
                } else {
                    Picker("Billing team", selection: $integration.account) {
                        Text("Default team").tag("")
                        ForEach(vercelAccounts) { Text("\($0.name) (\($0.slug))").tag($0.id) }
                        if !integration.account.isEmpty && !vercelAccounts.contains(where: { $0.id == integration.account }) {
                            Text(integration.account).tag(integration.account)
                        }
                    }
                }
                if loadingAccounts { ProgressView().controlSize(.small) }
                Button("Load teams", systemImage: "arrow.clockwise") { loadVercelAccounts() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled((vercelOAuth && !signedIn) || loadingAccounts)
                    .help("Load teams from Vercel")
            }
            if let accountsError {
                Label(accountsError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            TextField("Project ID (optional)", text: $integration.resource)
            Text(vercelOAuth
                 ? "Billing charges require an Owner, Member, Developer, Security, Billing, or Enterprise Viewer role on the team, and the RxCode Vercel app must be granted the Team and Billing read permissions. Vercel returns HTTP 403 when either is missing."
                 : "Billing charges require an Owner, Member, Developer, Security, Billing, or Enterprise Viewer role on the team. Vercel returns HTTP 403 when the token's scope or role doesn't allow it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// Cloudflare OAuth apps cannot request Billing Read, so account consumption takes an optional API token.
    private var cloudflareBillingSection: some View {
        Section("Billing API token (optional)") {
            if hasBillingCredential {
                Label("Billing API token saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            SecureField(hasBillingCredential ? "Billing API token (leave blank to keep existing token)" : "Billing API token", text: $billingCredential)
            MarkdownContentView(text: "Cloudflare sign-in can't grant billing access. Create an API token at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) with **Account › Billing › Read** for this account ([billing permissions](https://developers.cloudflare.com/billing/understand/billing-permissions/)). Used only for account billing usage and stored only in Keychain.", style: .rxCodeCompact)
        }
    }

    @ViewBuilder private var cloudflareAccountPicker: some View {
        if cloudflareAccounts.isEmpty {
            TextField("Account ID", text: $integration.account)
        } else {
            Picker("Cloudflare account", selection: $integration.account) {
                Text("Choose an account").tag("")
                ForEach(cloudflareAccounts) { Text("\($0.name) (\($0.id))").tag($0.id) }
                if !integration.account.isEmpty && !cloudflareAccounts.contains(where: { $0.id == integration.account }) {
                    Text(integration.account).tag(integration.account)
                }
            }
        }
        Button("Reload accounts", systemImage: "arrow.clockwise") { accountRefreshID = UUID() }
            .disabled(!signedIn || loadingAccounts)
        if loadingAccounts { ProgressView("Loading accounts…").controlSize(.small) }
        if let accountsError {
            Text(accountsError).font(.caption).foregroundStyle(.orange)
        }
    }

    private func loadCloudflareAccounts() async {
        loadingAccounts = true
        accountsError = nil
        let current = integration
        defer { loadingAccounts = false }
        do {
            let accounts = try await UsageOAuthTokens.shared.withAccessToken(current) { token in
                guard let token else { throw UsagePluginError.invalidConfiguration }
                return try await CloudflareAccounts.list(token: token)
            }
            try Task.checkCancellation()
            guard integration.id == current.id && integration.pluginID == "cloudflare" else { return }
            cloudflareAccounts = accounts
            if integration.account.isEmpty && accounts.count == 1 { integration.account = accounts[0].id }
            if accounts.isEmpty { accountsError = "No active accounts found. Enter an account ID manually." }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            cloudflareAccounts = []
            accountsError = "Could not load accounts (\(error.localizedDescription)). Enter an account ID manually, or sign in again to grant membership read access."
        }
    }

    private func loadVercelAccounts() {
        loadingAccounts = true; accountsError = nil
        let current = integration
        let typed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        let useOAuth = vercelOAuth
        Task {
            defer { loadingAccounts = false }
            do {
                let token = useOAuth
                    ? try await UsageOAuthTokens.shared.accessToken(current)
                    : (typed.isEmpty ? await UsageDashboardStore.shared.credential(for: current.id) : typed)
                guard let token, !token.isEmpty else { return }
                vercelAccounts = try await VercelAccounts.list(token: token)
            } catch {
                vercelAccounts = []
                accountsError = useOAuth
                    ? "Could not load teams (\(error.localizedDescription)). Enter the team ID or slug, or sign in again after the app is granted Team read access."
                    : "Could not load teams (\(error.localizedDescription)). Enter the team ID or slug, or check the access token."
            }
        }
    }
    private func save() {
        busy = true
        if usesOAuth && integration.pluginID != "vercel" { integration.oauth = oauth }
        if integration.pluginID == "cloudflare" {
            integration.resource = cloudflareScope.resource(named: cloudflareResource.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Task {
            defer { busy = false }
            do {
                if !credential.isEmpty { try await UsageDashboardStore.shared.saveCredential(credential, id: integration.id) }
                if vercel && !gatewayCredential.isEmpty {
                    try await UsageDashboardStore.shared.saveGatewayCredential(gatewayCredential, id: integration.id)
                }
                let billingToken = billingCredential.trimmingCharacters(in: .whitespacesAndNewlines)
                if integration.pluginID == "cloudflare" && !billingToken.isEmpty {
                    try await UsageDashboardStore.shared.saveBillingCredential(billingToken, id: integration.id)
                }
                var dashboard = appState.usageDashboard
                if let index = dashboard.integrations.firstIndex(where: { $0.id == integration.id }) {
                    dashboard.integrations[index] = integration
                    dashboard.snapshots.removeAll { $0.id == integration.id }
                } else {
                    dashboard.integrations.append(integration)
                    dashboard.cards.append(.init(integrationID: integration.id))
                }
                guard await appState.updateUsageDashboard(dashboard) else { error = appState.usageDashboardError; return }
                await appState.refreshUsagePlugins()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
