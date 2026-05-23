import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI
import UIKit
import os.log
extension MobileAppState {
    // MARK: - Remote desktop configuration

    /// Timeout after which a stuck remote config request is cleared and an
    /// error surfaced. ACP installs download a binary, so they get longer.
    static let remoteConfigTimeout: Duration = .seconds(20)
    static let acpInstallTimeout: Duration = .seconds(90)

    /// Runs `perform` on the main actor after `timeout`. Callers use it to
    /// expire a request that never received a reply (relay dropped, etc.).
    func scheduleTimeout(
        _ timeout: Duration,
        perform: @escaping (MobileAppState) -> Void
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self else { return }
            perform(self)
        }
    }

    // Skills

    func requestSkillCatalog(forceRefresh: Bool = false) async {
        guard isPaired else {
            skillCatalogError = String(localized: "Connect a Mac to browse skills.")
            return
        }
        let payload = SkillCatalogRequestPayload(forceRefresh: forceRefresh)
        pendingSkillCatalogRequestID = payload.clientRequestID
        skillCatalogLoading = true
        skillCatalogError = nil
        do {
            try await client.send(.skillCatalogRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.pendingSkillCatalogRequestID == payload.clientRequestID {
                    s.pendingSkillCatalogRequestID = nil
                    s.skillCatalogLoading = false
                    s.skillCatalogError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            skillCatalogLoading = false
            skillCatalogError = String(localized: "Failed to request skills: \(error.localizedDescription)")
            if pendingSkillCatalogRequestID == payload.clientRequestID {
                pendingSkillCatalogRequestID = nil
            }
        }
    }

    func installSkill(_ pluginID: String) async {
        await mutateSkill(pluginID, operation: .install)
    }

    func uninstallSkill(_ pluginID: String) async {
        await mutateSkill(pluginID, operation: .uninstall)
    }

    func addSkillGitSource(url: String, ref: String?) async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            lastSkillError = String(localized: "Enter a GitHub repository URL.")
            return
        }
        let trimmedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "add:\(trimmedURL)"
        await mutateSkillSource(
            key: key,
            operation: .add,
            gitURL: trimmedURL,
            ref: trimmedRef?.isEmpty == false ? trimmedRef : nil
        )
    }

    func removeSkillGitSource(_ sourceID: String) async {
        await mutateSkillSource(key: sourceID, operation: .remove, sourceID: sourceID)
    }

    func mutateSkill(_ pluginID: String, operation: SkillMutationRequestPayload.Operation) async {
        guard isPaired else {
            lastSkillError = String(localized: "Connect a Mac first.")
            return
        }
        guard !inFlightSkillMutations.contains(pluginID) else { return }
        let payload = SkillMutationRequestPayload(operation: operation, pluginID: pluginID)
        inFlightSkillMutations.insert(pluginID)
        lastSkillError = nil
        do {
            try await client.send(.skillMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.inFlightSkillMutations.remove(pluginID) != nil {
                    s.lastSkillError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            inFlightSkillMutations.remove(pluginID)
            lastSkillError = String(localized: "Failed to send request: \(error.localizedDescription)")
        }
    }

    func mutateSkillSource(
        key: String,
        operation: SkillSourceMutationRequestPayload.Operation,
        sourceID: String? = nil,
        gitURL: String? = nil,
        ref: String? = nil
    ) async {
        guard isPaired else {
            lastSkillError = String(localized: "Connect a Mac first.")
            return
        }
        guard !inFlightSkillSourceMutations.contains(key) else { return }
        let payload = SkillSourceMutationRequestPayload(
            operation: operation,
            sourceID: sourceID,
            gitURL: gitURL,
            ref: ref
        )
        inFlightSkillSourceMutations.insert(key)
        skillSourceMutationKeys[payload.clientRequestID] = key
        lastSkillError = nil
        do {
            try await client.send(.skillSourceMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if let key = s.skillSourceMutationKeys.removeValue(forKey: payload.clientRequestID) {
                    s.inFlightSkillSourceMutations.remove(key)
                    s.lastSkillError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            skillSourceMutationKeys.removeValue(forKey: payload.clientRequestID)
            inFlightSkillSourceMutations.remove(key)
            lastSkillError = String(localized: "Failed to send request: \(error.localizedDescription)")
        }
    }

    // ACP agent clients

    func requestACPRegistry(forceRefresh: Bool = false) async {
        guard isPaired else {
            acpRegistryError = String(localized: "Connect a Mac to manage agents.")
            return
        }
        let payload = ACPRegistryRequestPayload(forceRefresh: forceRefresh)
        pendingACPRegistryRequestID = payload.clientRequestID
        acpRegistryLoading = true
        acpRegistryError = nil
        do {
            try await client.send(.acpRegistryRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.pendingACPRegistryRequestID == payload.clientRequestID {
                    s.pendingACPRegistryRequestID = nil
                    s.acpRegistryLoading = false
                    s.acpRegistryError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            acpRegistryLoading = false
            acpRegistryError = String(localized: "Failed to request agents: \(error.localizedDescription)")
            if pendingACPRegistryRequestID == payload.clientRequestID {
                pendingACPRegistryRequestID = nil
            }
        }
    }

    func installACPAgent(_ registryAgentID: String) async {
        await mutateACP(operation: .install, key: registryAgentID, registryAgentID: registryAgentID)
    }

    func uninstallACPClient(_ clientID: String) async {
        await mutateACP(operation: .uninstall, key: clientID, clientID: clientID)
    }

    func setACPClientEnabled(_ clientID: String, enabled: Bool) async {
        await mutateACP(operation: .setEnabled, key: clientID, clientID: clientID, enabled: enabled)
    }

    func mutateACP(
        operation: ACPMutationRequestPayload.Operation,
        key: String,
        registryAgentID: String? = nil,
        clientID: String? = nil,
        enabled: Bool? = nil
    ) async {
        guard isPaired else {
            lastACPError = String(localized: "Connect a Mac first.")
            return
        }
        guard !inFlightACPMutations.contains(key) else { return }
        let payload = ACPMutationRequestPayload(
            operation: operation,
            registryAgentID: registryAgentID,
            clientID: clientID,
            enabled: enabled
        )
        inFlightACPMutations.insert(key)
        acpMutationKeys[payload.clientRequestID] = key
        lastACPError = nil
        let timeout = operation == .install ? Self.acpInstallTimeout : Self.remoteConfigTimeout
        do {
            try await client.send(.acpMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(timeout) { s in
                if s.acpMutationKeys.removeValue(forKey: payload.clientRequestID) != nil {
                    s.inFlightACPMutations.remove(key)
                    s.lastACPError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            acpMutationKeys.removeValue(forKey: payload.clientRequestID)
            inFlightACPMutations.remove(key)
            lastACPError = String(localized: "Failed to send request: \(error.localizedDescription)")
        }
    }

    // MCP servers

    func requestMCPConfig() async {
        guard isPaired else {
            mcpConfigError = String(localized: "Connect a Mac to manage MCP servers.")
            return
        }
        let payload = MCPConfigRequestPayload()
        pendingMCPConfigRequestID = payload.clientRequestID
        mcpConfigLoading = true
        mcpConfigError = nil
        do {
            try await client.send(.mcpConfigRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.pendingMCPConfigRequestID == payload.clientRequestID {
                    s.pendingMCPConfigRequestID = nil
                    s.mcpConfigLoading = false
                    s.mcpConfigError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            mcpConfigLoading = false
            mcpConfigError = String(localized: "Failed to request MCP servers: \(error.localizedDescription)")
            if pendingMCPConfigRequestID == payload.clientRequestID {
                pendingMCPConfigRequestID = nil
            }
        }
    }

    func addMCPServer(_ server: MobileMCPServer) async {
        await mutateMCP(operation: .add, serverName: server.name, server: server)
    }

    func removeMCPServer(_ serverName: String) async {
        await mutateMCP(operation: .remove, serverName: serverName)
    }

    func setMCPServerEnabled(_ serverName: String, enabled: Bool) async {
        await mutateMCP(operation: .setEnabled, serverName: serverName, enabled: enabled)
    }

    func mutateMCP(
        operation: MCPMutationRequestPayload.Operation,
        serverName: String,
        server: MobileMCPServer? = nil,
        enabled: Bool? = nil
    ) async {
        guard isPaired else {
            lastMCPError = String(localized: "Connect a Mac first.")
            return
        }
        guard !inFlightMCPMutations.contains(serverName) else { return }
        let payload = MCPMutationRequestPayload(
            operation: operation,
            serverName: serverName,
            server: server,
            enabled: enabled
        )
        inFlightMCPMutations.insert(serverName)
        lastMCPError = nil
        do {
            try await client.send(.mcpMutationRequest(payload), toHex: pairedDesktopPubkey)
            scheduleTimeout(Self.remoteConfigTimeout) { s in
                if s.inFlightMCPMutations.remove(serverName) != nil {
                    s.lastMCPError = String(localized: "Request timed out. Check your Mac and try again.")
                }
            }
        } catch {
            inFlightMCPMutations.remove(serverName)
            lastMCPError = String(localized: "Failed to send request: \(error.localizedDescription)")
        }
    }
}
