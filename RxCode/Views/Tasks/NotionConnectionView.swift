import RxCodeCore
import SwiftUI

/// The Notion connection controls shared by Settings → Tasks and the Notion
/// sheet: "Connect with Notion" (OAuth through a chosen relay server), or an
/// internal integration token pasted by hand; once connected, the workspace,
/// the relay, and a Disconnect button.
///
/// The relay list follows Settings → Mobile — every configured relay server —
/// plus the hosted presets, so a self-hosted relay can run the sign-in.
struct NotionConnectionView: View {
    @Environment(AppState.self) private var appState

    /// Called after connecting, e.g. to load the database list.
    var onConnected: () -> Void = {}

    @State private var isConnecting = false
    @State private var showsTokenField = false
    @State private var tokenDraft = ""
    @State private var error: String?
    @State private var relays: [NotionRelayOption] = []
    @State private var selectedRelay: NotionRelayOption?

    var body: some View {
        Group {
            if appState.hasNotionToken {
                connected
            } else {
                disconnected
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
        }
        .onAppear {
            appState.refreshNotionTokenState()
            reloadRelays()
        }
        .task {
            // Pick up hosted relays published since launch.
            await RelayPresetCatalog.shared.refresh()
            reloadRelays()
        }
    }

    private var connected: some View {
        LabeledContent {
            Button("Disconnect", role: .destructive) {
                run { try await appState.disconnectNotion() }
            }
            .accessibilityIdentifier("notion-disconnect")
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let workspace = appState.notionWorkspaceName {
                        Text("Connected to \(workspace)")
                    } else {
                        Text("Connected with an integration token")
                    }
                    if let relayURL = appState.notionRelayURL {
                        Text("Via \(appState.notionRelayName(for: relayURL))")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ClaudeTheme.statusSuccess)
            }
        }
    }

    @ViewBuilder
    private var disconnected: some View {
        Picker("Relay server", selection: $selectedRelay) {
            if relays.isEmpty {
                Text("No relay servers").tag(NotionRelayOption?.none)
            }
            ForEach(relays) { relay in
                Text("\(relay.name) — \(relay.baseURL.host ?? relay.baseURL.absoluteString)")
                    .tag(Optional(relay))
            }
        }
        .disabled(relays.isEmpty)
        .help("Relay servers from Settings → Mobile and RxLab's hosted relays. The relay must have Notion sign-in configured.")
        .accessibilityIdentifier("notion-relay-picker")

        HStack(spacing: 8) {
            Button {
                guard let relay = selectedRelay else { return }
                run {
                    try await appState.connectNotionWithOAuth(relay: relay)
                    onConnected()
                }
            } label: {
                Label("Connect with Notion", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting || selectedRelay == nil)
            .accessibilityIdentifier("notion-connect")

            if isConnecting {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(showsTokenField ? "Hide token" : "Use a token instead") {
                showsTokenField.toggle()
            }
            .buttonStyle(.link)
        }

        if showsTokenField {
            HStack(spacing: 8) {
                SecureField("Internal integration token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("notion-token-field")
                Button("Save") {
                    let token = tokenDraft
                    run {
                        try await appState.setNotionToken(token)
                        tokenDraft = ""
                        onConnected()
                    }
                }
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func reloadRelays() {
        relays = appState.notionRelayOptions()
        if selectedRelay.map({ !relays.contains($0) }) ?? true {
            selectedRelay = appState.preferredNotionRelay(in: relays)
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        isConnecting = true
        error = nil
        Task {
            defer { isConnecting = false }
            do {
                try await action()
            } catch NotionOAuthError.cancelled {
                // The user closed the sign-in window.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
