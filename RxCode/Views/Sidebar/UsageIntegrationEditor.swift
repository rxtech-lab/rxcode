import SwiftUI
import RxCodeCore

struct UsageIntegrationEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var integration: UsageIntegration
    @State private var credential = ""
    @State private var oauth = UsageOAuthConfiguration()
    @State private var busy = false
    @State private var error: String?
    @State private var signedIn = false
    @State private var signIn = UsageOAuthSignIn()
    private var local: Bool { integration.pluginID.hasPrefix("ai-") }
    private var usesOAuth: Bool { ["vercel", "cloudflare"].contains(integration.pluginID) }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Integration", selection: $integration.pluginID) {
                    ForEach(AppState.usagePluginIDs, id: \.self) { Text($0).tag($0) }
                }.disabled(appState.usageDashboard.integrations.contains(where: { $0.id == integration.id }))
                TextField("Title", text: $integration.title)
                Picker("RxCode project", selection: $integration.projectID) {
                    Text("All projects").tag(UUID?.none)
                    ForEach(appState.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                if !local {
                    TextField(integration.pluginID == "github-ci" ? "Repositories (owner/repo, comma separated)" : "Account / organization / team ID", text: $integration.account)
                    if integration.pluginID != "github-ci" {
                        TextField(integration.pluginID == "turso" ? "Database name (optional)" : (integration.pluginID == "cloudflare" ? "Zone ID (optional; traffic analytics)" : "Provider project ID (optional)"), text: $integration.resource)
                    }
                    if usesOAuth {
                        Section("OAuth application") {
                            TextField("Public client ID", text: $oauth.clientID)
                            TextField("Callback URL", text: $oauth.callbackURL)
                            TextField("Scopes", text: $oauth.scopes)
                            Text("Register a public PKCE client with callback rxcode://usage-oauth. Grant read access to usage or billing in the provider console.").font(.caption).foregroundStyle(.secondary)
                            if integration.pluginID == "vercel" {
                                Text("Vercel currently gates team API permissions behind private beta. Your app needs Billing: Read Only permission.").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(signedIn ? "Sign in again" : "Sign in with \(integration.pluginID.capitalized)") {
                                busy = true
                                integration.oauth = oauth
                                Task {
                                    defer { busy = false }
                                    do { try await signIn.signIn(integration); signedIn = true }
                                    catch { self.error = error.localizedDescription }
                                }
                            }.disabled(oauth.clientID.isEmpty || busy)
                        }
                    } else {
                        SecureField("API key (leave blank to keep existing key)", text: $credential)
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle("Usage integration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy || integration.title.isEmpty || (!local && integration.account.isEmpty)) }
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 540, maxHeight: .infinity)
        .onAppear { oauth = integration.oauth ?? .init(scopes: integration.pluginID == "vercel" ? "openid offline_access" : "") }
        .overlay { if busy { ProgressView("Updating integration…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("Integration could not be updated", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func save() {
        busy = true
        if usesOAuth { integration.oauth = oauth }
        Task {
            defer { busy = false }
            do {
                if !credential.isEmpty { try await UsageDashboardStore.shared.saveCredential(credential, id: integration.id) }
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
