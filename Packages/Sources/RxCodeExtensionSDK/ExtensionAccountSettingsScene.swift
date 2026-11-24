#if os(macOS)
import ExtensionKit
import Foundation
import SwiftUI

public struct ExtensionUsageAccount: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    private struct Selection: Codable {
        let account: String
        let configuredAccount: String
    }
    private struct Write: Encodable {
        let key: String
        let value: Selection
    }

    public static func selected(for integration: ExtensionUsageIntegration, host: RxCodeHost) async throws -> String {
        let saved = try await host.call(.storageGet, ["key": "account.\(integration.id)"], returning: Selection?.self)
        // Editing the account directly in RxCode takes precedence over an older picker selection.
        guard let saved, saved.configuredAccount == integration.account else { return integration.account }
        return saved.account
    }

    public static func select(_ account: String, for integration: ExtensionUsageIntegration, host: RxCodeHost) async throws {
        let write = Write(key: "account.\(integration.id)", value: Selection(account: account, configuredAccount: integration.account))
        _ = try await host.call(.storageSet, write, returning: Selection.self)
    }
}

/// A connection scene binds its account picker and storage operations to the integration opened by RxCode.
@MainActor public func extensionAccountSettingsScene(
    accounts: @escaping @Sendable (RxCodeHost) async throws -> [ExtensionUsageAccount]
) -> PrimitiveAppExtensionScene {
    let state = ConnectionSettingsState()
    return PrimitiveAppExtensionScene(id: "settings") {
        ConnectionSettingsView(state: state, accounts: accounts)
    } onConnection: { connection in
        ExtensionSceneConnection.accept(connection) { context, host in
            Task { @MainActor in state.bind(context, host: host) }
        }
    }
}

func sdkText(_ key: String.LocalizationValue) -> String {
    #if SWIFT_PACKAGE
    String(localized: key, bundle: .module)
    #else
    String(localized: key, table: "RxCodeExtensionSDK")
    #endif
}

@MainActor @Observable
private final class ConnectionSettingsState {
    var integration: ExtensionUsageIntegration?
    var host: RxCodeHost?
    var revision = UUID()

    func bind(_ context: ExtensionSceneContext, host: RxCodeHost) {
        self.host = host
        integration = context.configuration.flatMap { try? JSONDecoder().decode(ExtensionUsageIntegration.self, from: $0) }
        revision = UUID()
    }
}

private struct ConnectionSettingsView: View {
    let state: ConnectionSettingsState
    let accounts: @Sendable (RxCodeHost) async throws -> [ExtensionUsageAccount]
    @State private var account = ""
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        Group {
            if let integration = state.integration, let host = state.host {
                Form {
                    LabeledContent(sdkText("Account"), value: account.isEmpty ? sdkText("Default") : account)
                    Button(sdkText("Choose account…")) { choosing = true }
                }
                .formStyle(.grouped)
                .sheet(isPresented: $choosing) {
                    MembershipPicker(integration: integration, host: host, loadAccounts: accounts, selected: $account)
                }
                .task(id: state.revision) {
                    do {
                        let selected = try await ExtensionUsageAccount.selected(for: integration, host: host)
                        try Task.checkCancellation()
                        account = selected
                    } catch {
                        if !Task.isCancelled { self.error = error.localizedDescription }
                    }
                }
            } else {
                ContentUnavailableView(sdkText("Choose a usage integration"), systemImage: "person.crop.circle",
                                       description: Text(sdkText("Open connection settings for the integration in the usage dashboard.")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(sdkText("Could not load account"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(sdkText("OK"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

private struct MembershipPicker: View {
    let integration: ExtensionUsageIntegration
    let host: RxCodeHost
    let loadAccounts: @Sendable (RxCodeHost) async throws -> [ExtensionUsageAccount]
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [ExtensionUsageAccount] = []
    @State private var draft: String?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if accounts.isEmpty {
                    ContentUnavailableView(sdkText("No accounts available"), systemImage: "person.2")
                } else {
                    List(accounts, selection: $draft) { Text($0.name).tag($0.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(sdkText("Select an account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sdkText("Cancel")) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sdkText("Save")) { Task { await save() } }.disabled(draft == nil || saving)
                }
            }
            .overlay { if saving { ProgressView(sdkText("Saving account…")).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        }
        .frame(minWidth: 400, minHeight: 380, maxHeight: .infinity)
        .interactiveDismissDisabled(saving)
        .alert(sdkText("Connection settings"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(sdkText("OK"), role: .cancel) {}
        } message: { Text(error ?? "") }
        .task {
            do {
                accounts = try await loadAccounts(host)
                draft = accounts.first { $0.id == selected }?.id
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    private func save() async {
        guard let draft, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await ExtensionUsageAccount.select(draft, for: integration, host: host)
            selected = draft
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
