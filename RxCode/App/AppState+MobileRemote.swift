import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Mobile: Skills / ACP / MCP remote management

    /// Error for malformed remote skill/ACP/MCP requests; its description is
    /// surfaced verbatim to the mobile client.
    enum MobileRemoteConfigError: LocalizedError {
        case invalidRequest(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest(let detail): return detail
            }
        }
    }

    /// The marketplace catalog flattened into wire DTOs with current install
    /// state. `forceRefresh` bypasses the 5-minute marketplace cache.
    func mobileSkillPlugins(forceRefresh: Bool = false) async -> [MobileSkillPlugin] {
        let catalog = await marketplace.fetchCatalog(forceRefresh: forceRefresh)
        let installed = await marketplace.installedPluginNames()
        return catalog.map { plugin in
            MobileSkillPlugin(
                id: plugin.id,
                name: plugin.name,
                summary: plugin.description,
                author: plugin.author,
                category: plugin.category,
                categoryLabel: plugin.categoryLabel,
                marketplace: plugin.marketplace,
                marketplaceLabel: plugin.marketplaceLabel,
                homepage: plugin.homepage,
                isInstalled: installed.contains(plugin.name)
            )
        }
    }

    func mobileSkillSources() async -> [MobileSkillSource] {
        await marketplace.customSources().map { source in
            MobileSkillSource(id: source.id, displayName: source.displayName)
        }
    }

    func handleMobileSkillCatalogRequest(_ request: SkillCatalogRequestPayload, fromHex: String) async {
        logger.info("[MobileSync] skill catalog handler start requestID=\(request.clientRequestID.uuidString, privacy: .public) forceRefresh=\(request.forceRefresh, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        let plugins = await mobileSkillPlugins(forceRefresh: request.forceRefresh)
        let sources = await mobileSkillSources()
        logger.info("[MobileSync] skill catalog handler result requestID=\(request.clientRequestID.uuidString, privacy: .public) plugins=\(plugins.count, privacy: .public) sources=\(sources.count, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        let result = SkillCatalogResultPayload(
            clientRequestID: request.clientRequestID,
            ok: true,
            errorMessage: nil,
            plugins: plugins,
            sources: sources
        )
        await MobileSyncService.shared.send(.skillCatalogResult(result), toHex: fromHex)
    }

    func handleMobileSkillMutationRequest(_ request: SkillMutationRequestPayload, fromHex: String) async {
        let catalog = await marketplace.fetchCatalog()
        guard let plugin = catalog.first(where: { $0.id == request.pluginID }) else {
            let result = SkillMutationResultPayload(
                clientRequestID: request.clientRequestID,
                operation: request.operation,
                pluginID: request.pluginID,
                ok: false,
                errorMessage: "Skill not found in the marketplace catalog.",
                plugins: await mobileSkillPlugins(),
                sources: await mobileSkillSources()
            )
            await MobileSyncService.shared.send(.skillMutationResult(result), toHex: fromHex)
            return
        }

        var ok = true
        var errorMessage: String?
        do {
            switch request.operation {
            case .install:
                try await marketplace.installPlugin(plugin)
                marketplaceInstalledNames.insert(plugin.name)
                marketplacePluginStates[plugin.id] = .installed
            case .uninstall:
                try await marketplace.uninstallPlugin(plugin)
                marketplaceInstalledNames.remove(plugin.name)
                marketplacePluginStates[plugin.id] = .notInstalled
            }
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] skill mutation failed plugin=\(plugin.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if ok {
            let verb = request.operation == .install ? "installed" : "removed"
            await hookManager.dispatchRemoteConfigChanged(RemoteConfigChangedPayload(
                title: "Skill \(verb) remotely",
                body: plugin.name
            ))
        }

        let result = SkillMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            pluginID: request.pluginID,
            ok: ok,
            errorMessage: errorMessage,
            plugins: await mobileSkillPlugins(),
            sources: await mobileSkillSources()
        )
        await MobileSyncService.shared.send(.skillMutationResult(result), toHex: fromHex)
    }

    func handleMobileSkillSourceMutationRequest(_ request: SkillSourceMutationRequestPayload, fromHex: String) async {
        var ok = true
        var errorMessage: String?
        var sourceID = request.sourceID
        var bannerTitle: String?
        var bannerBody: String?

        do {
            switch request.operation {
            case .add:
                guard let gitURL = request.gitURL,
                      !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MobileRemoteConfigError.invalidRequest("Missing Git repository URL.")
                }
                let source = try await marketplace.addCustomGitSource(url: gitURL, ref: request.ref)
                sourceID = source.id
                marketplaceCustomSources = await marketplace.customSources()
                bannerTitle = "Skill Git source added remotely"
                bannerBody = source.displayName
            case .remove:
                let currentSources = await marketplace.customSources()
                guard let sourceID = request.sourceID,
                      let source = currentSources.first(where: { $0.id == sourceID }) else {
                    throw MobileRemoteConfigError.invalidRequest("Skill Git source not found.")
                }
                try await marketplace.removeCustomGitSource(source)
                marketplaceCustomSources = await marketplace.customSources()
                bannerTitle = "Skill Git source removed remotely"
                bannerBody = source.displayName
            }
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] skill source mutation failed operation=\(request.operation.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let plugins = await mobileSkillPlugins(forceRefresh: true)
        let sources = await mobileSkillSources()
        marketplaceCatalog = await marketplace.fetchCatalog()
        marketplaceInstalledNames = await marketplace.installedPluginNames()

        if ok, let bannerTitle, let bannerBody {
            await hookManager.dispatchRemoteConfigChanged(RemoteConfigChangedPayload(title: bannerTitle, body: bannerBody))
        }

        let result = SkillSourceMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            sourceID: sourceID,
            ok: ok,
            errorMessage: errorMessage,
            plugins: plugins,
            sources: sources
        )
        await MobileSyncService.shared.send(.skillSourceMutationResult(result), toHex: fromHex)
    }

    func mobileACPRegistryAgents() -> [MobileACPRegistryAgent] {
        let installedRegistryIDs = Set(acpClients.compactMap(\.registryId))
        return (acpRegistry?.agents ?? []).map { agent in
            MobileACPRegistryAgent(
                id: agent.id,
                name: agent.name,
                version: agent.version,
                summary: agent.description,
                authors: agent.authors ?? [],
                license: agent.license,
                website: agent.website,
                iconURL: agent.icon,
                isInstalled: installedRegistryIDs.contains(agent.id),
                hasBinary: agent.distribution.binary?[ACPPlatform.current] != nil,
                hasNpx: agent.distribution.npx != nil,
                hasUvx: agent.distribution.uvx != nil
            )
        }
    }

    func mobileACPClients() -> [MobileACPClient] {
        acpClients.map { spec in
            MobileACPClient(
                id: spec.id,
                registryId: spec.registryId,
                displayName: spec.displayName,
                enabled: spec.enabled,
                launchKind: spec.launch.displayKind,
                modelCount: spec.models.count,
                iconURL: spec.iconURL
            )
        }
    }

    func handleMobileACPRegistryRequest(_ request: ACPRegistryRequestPayload, fromHex: String) async {
        logger.info("[MobileSync] acp registry handler start requestID=\(request.clientRequestID.uuidString, privacy: .public) forceRefresh=\(request.forceRefresh, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        await refreshACPRegistry(forceRefresh: request.forceRefresh)
        let ok = acpRegistry != nil
        let agents = mobileACPRegistryAgents()
        let clients = mobileACPClients()
        logger.info("[MobileSync] acp registry handler result requestID=\(request.clientRequestID.uuidString, privacy: .public) ok=\(ok, privacy: .public) agents=\(agents.count, privacy: .public) clients=\(clients.count, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        let result = ACPRegistryResultPayload(
            clientRequestID: request.clientRequestID,
            ok: ok,
            errorMessage: ok ? nil : "Could not load the ACP agent registry.",
            registryAgents: agents,
            installedClients: clients
        )
        await MobileSyncService.shared.send(.acpRegistryResult(result), toHex: fromHex)
    }

    func handleMobileACPMutationRequest(_ request: ACPMutationRequestPayload, fromHex: String) async {
        var ok = true
        var errorMessage: String?
        var bannerTitle: String?
        var bannerBody: String?
        do {
            switch request.operation {
            case .install:
                guard let agentID = request.registryAgentID else {
                    throw MobileRemoteConfigError.invalidRequest("Missing registry agent id.")
                }
                if acpRegistry == nil { await refreshACPRegistry() }
                guard let agent = acpRegistry?.agents.first(where: { $0.id == agentID }) else {
                    throw MobileRemoteConfigError.invalidRequest("Agent not found in the registry.")
                }
                let spec = try await installACPClient(from: agent)
                addACPClient(spec)
                bannerTitle = "ACP agent installed remotely"
                bannerBody = agent.name
            case .uninstall:
                guard let clientID = request.clientID,
                      let client = acpClients.first(where: { $0.id == clientID })
                else {
                    throw MobileRemoteConfigError.invalidRequest("Installed client not found.")
                }
                removeACPClient(id: clientID)
                bannerTitle = "ACP agent removed remotely"
                bannerBody = client.displayName
            case .setEnabled:
                guard let clientID = request.clientID,
                      let enabled = request.enabled,
                      var client = acpClients.first(where: { $0.id == clientID })
                else {
                    throw MobileRemoteConfigError.invalidRequest("Installed client not found.")
                }
                client.enabled = enabled
                updateACPClient(client)
                bannerTitle = "ACP agent \(enabled ? "enabled" : "disabled") remotely"
                bannerBody = client.displayName
            }
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] acp mutation failed operation=\(request.operation.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if ok, let bannerTitle, let bannerBody {
            await hookManager.dispatchRemoteConfigChanged(RemoteConfigChangedPayload(title: bannerTitle, body: bannerBody))
        }

        let result = ACPMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            ok: ok,
            errorMessage: errorMessage,
            registryAgents: mobileACPRegistryAgents(),
            installedClients: mobileACPClients()
        )
        await MobileSyncService.shared.send(.acpMutationResult(result), toHex: fromHex)
    }

    func mobileMCPServer(_ record: MCPServerRecord) -> MobileMCPServer {
        let env = record.env
            .sorted { $0.key < $1.key }
            .map { MobileMCPKeyValue(key: $0.key, value: $0.value) }
        let headers = record.headers
            .sorted { $0.key < $1.key }
            .map { MobileMCPKeyValue(key: $0.key, value: $0.value) }
        let endpoint: String
        if record.transport == .stdio {
            endpoint = ([record.command ?? ""] + record.args)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else {
            endpoint = record.url ?? ""
        }
        return MobileMCPServer(
            name: record.name,
            transport: record.transport.rawValue,
            url: record.url,
            command: record.command,
            args: record.args,
            env: env,
            headers: headers,
            isGloballyEnabled: record.isGloballyEnabled,
            endpoint: endpoint
        )
    }

    func mobileMCPServers() async throws -> [MobileMCPServer] {
        try await mcp.globalRecords().map { mobileMCPServer($0) }
    }

    func mcpServerSpec(from server: MobileMCPServer) -> MCPServerSpec {
        MCPServerSpec(
            name: server.name,
            transport: MCPTransport(rawValue: server.transport) ?? .stdio,
            url: server.url ?? "",
            headers: server.headers.map { MCPKeyValue(key: $0.key, value: $0.value) },
            command: server.command ?? "",
            args: server.args,
            env: server.env.map { MCPKeyValue(key: $0.key, value: $0.value) }
        )
    }

    func handleMobileMCPConfigRequest(_ request: MCPConfigRequestPayload, fromHex: String) async {
        do {
            let servers = try await mobileMCPServers()
            let result = MCPConfigResultPayload(
                clientRequestID: request.clientRequestID,
                ok: true,
                errorMessage: nil,
                servers: servers
            )
            await MobileSyncService.shared.send(.mcpConfigResult(result), toHex: fromHex)
        } catch {
            let result = MCPConfigResultPayload(
                clientRequestID: request.clientRequestID,
                ok: false,
                errorMessage: error.localizedDescription,
                servers: []
            )
            await MobileSyncService.shared.send(.mcpConfigResult(result), toHex: fromHex)
        }
    }

    func handleMobileMCPMutationRequest(_ request: MCPMutationRequestPayload, fromHex: String) async {
        var ok = true
        var errorMessage: String?
        var bannerTitle: String?
        do {
            switch request.operation {
            case .add:
                guard let server = request.server else {
                    throw MobileRemoteConfigError.invalidRequest("Missing server definition.")
                }
                try await mcp.add(spec: mcpServerSpec(from: server), scope: .user, projectPath: nil)
                bannerTitle = "MCP server saved remotely"
            case .remove:
                try await mcp.remove(name: request.serverName, scope: .user)
                bannerTitle = "MCP server removed remotely"
            case .setEnabled:
                guard let enabled = request.enabled else {
                    throw MobileRemoteConfigError.invalidRequest("Missing enabled flag.")
                }
                try await mcp.setGlobalEnabled(name: request.serverName, enabled: enabled)
                bannerTitle = "MCP server \(enabled ? "enabled" : "disabled") remotely"
            }
            await refreshMCPServers()
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] mcp mutation failed server=\(request.serverName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if ok, let bannerTitle {
            await hookManager.dispatchRemoteConfigChanged(RemoteConfigChangedPayload(title: bannerTitle, body: request.serverName))
        }

        var servers: [MobileMCPServer] = []
        do {
            servers = try await mobileMCPServers()
        } catch {
            logger.error("[MobileSync] failed reading mcp servers for reply: \(error.localizedDescription, privacy: .public)")
        }
        let result = MCPMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            serverName: request.serverName,
            ok: ok,
            errorMessage: errorMessage,
            servers: servers
        )
        await MobileSyncService.shared.send(.mcpMutationResult(result), toHex: fromHex)
    }

    func handleMobileCancelStream(_ cancel: CancelStreamPayload) async {
        // The mobile may hold a session id the CLI has since advanced
        // (pending-→real swap, or a compaction boundary). Follow the redirect
        // chain so the cancel lands on the live, streaming thread — otherwise
        // `sessionStates[sessionID]` is nil and the stop button is a no-op.
        let sessionID = resolveCurrentSessionId(cancel.sessionID)
        guard sessionStates[sessionID]?.isStreaming == true else {
            logger.info("[MobileSync] cancel ignored — thread=\(sessionID, privacy: .public) (from \(cancel.sessionID, privacy: .public)) is not streaming")
            return
        }
        let window = WindowState()
        window.currentSessionId = sessionID
        // Resolve the project so cancelStreaming can persist the partial
        // messages accumulated up to the cancellation point.
        if let summary = allSessionSummaries.first(where: { $0.id == sessionID }) {
            window.selectedProject = projects.first(where: { $0.id == summary.projectId })
        }
        await cancelStreaming(in: window)
        // cancelStreaming intentionally skips finalizeStreamSession, so no
        // status update is emitted — broadcast it so the mobile flips its
        // stop button back to send.
        broadcastMobileSessionStatus(sessionID: sessionID)
    }

    func handleMobileUserMessage(_ message: UserMessagePayload, fromHex: String) async {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let sessionID = resolveCurrentSessionId(message.sessionID)
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else {
            logger.error("[MobileSync] user message for unknown thread=\(message.sessionID, privacy: .public)")
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        await hydrateSessionIfNeeded(summary: summary, project: project)
        updateMobilePlaceholderTitleIfNeeded(sessionID: sessionID, firstUserMessage: text)

        // If a turn is already streaming, the mobile message goes into the
        // shared (threadStore-backed) queue so it flushes once the current turn
        // ends — same behavior as the macOS InputBarView's enqueue path.
        if sessionStates[sessionID]?.isStreaming == true {
            let queued = QueuedMessage(text: text, attachments: [])
            threadStore.appendQueued(sessionKey: sessionID, message: queued)
            appendToWindowQueueMirrors(sessionID: sessionID, message: queued)
            broadcastMobileSessionStatus(sessionID: sessionID)
            return
        }

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionID
        if sessionID.hasPrefix("pending-mobile-") {
            window.insertPendingPlaceholder(sessionID)
        }
        _ = await sendPrompt(text, displayText: text, in: window)
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: window.currentSessionId)
    }

    func handleMobileQueueAction(_ payload: QueueMessageActionPayload) async {
        let sessionID = resolveCurrentSessionId(payload.sessionID)
        guard let target = threadStore.loadQueue(sessionKey: sessionID).first(where: { $0.id == payload.queuedMessageID }) else { return }
        if let text = payload.text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            threadStore.editQueued(id: target.id, text: text)
            for window in registeredWindows() {
                if window.currentSessionId == sessionID,
                   let index = window.messageQueue.firstIndex(where: { $0.id == target.id }) {
                    window.messageQueue[index].text = text
                }
                if let index = window.draftQueues[sessionID]?.firstIndex(where: { $0.id == target.id }) {
                    window.draftQueues[sessionID]?[index].text = text
                }
            }
        } else {
            guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
                  let project = projects.first(where: { $0.id == summary.projectId }) else { return }
            let window = WindowState()
            window.currentSessionId = sessionID
            window.selectedProject = project
            window.sessionAgentProvider = sessionStates[sessionID]?.agentProvider ?? summary.agentProvider
            window.sessionModel = sessionStates[sessionID]?.model ?? summary.model
            if await steerActiveStream(text: target.text, attachments: target.attachments, in: window) {
                handleMobileRemoveQueuedMessage(.init(sessionID: sessionID, queuedMessageID: target.id))
            }
        }
        broadcastMobileSessionStatus(sessionID: sessionID)
    }

    func handleMobileRemoveQueuedMessage(_ payload: RemoveQueuedMessagePayload) {
        threadStore.removeQueued(id: payload.queuedMessageID)
        evictFromWindowQueueMirrors(sessionID: payload.sessionID, queuedID: payload.queuedMessageID)
        broadcastMobileSessionStatus(sessionID: payload.sessionID)
    }

    /// Flushes the next queued message from threadStore as a new user turn.
    /// AppState is the single auto-flush authority — both macOS-side and
    /// mobile-side queued items are flushed here, so the two flows never
    /// race on duplicate sends. Triggered at the tail of `finalizeStreamSession`.
    ///
    /// Any macOS window currently viewing the session keeps a mirror copy of
    /// the queue in `window.messageQueue`; clear the popped entry from those
    /// mirrors so the UI doesn't show a stale queued row.
    func flushNextQueuedMessageIfNeeded(sessionID: String) async {
        let queue = threadStore.loadQueue(sessionKey: sessionID)
        guard let next = queue.first else { return }
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else { return }

        threadStore.removeQueued(id: next.id)
        evictFromWindowQueueMirrors(sessionID: sessionID, queuedID: next.id)
        broadcastMobileSessionStatus(sessionID: sessionID)

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionID
        _ = await sendPrompt(
            next.text,
            displayText: next.text,
            attachments: next.attachments,
            in: window
        )
    }

    /// Mirror of `enqueueMessage` for queue items appended by AppState itself
    /// (e.g. when a mobile-sent message arrives while the session is streaming).
    /// Every desktop window currently viewing the session keeps an in-memory
    /// copy in `messageQueue` and `draftQueues[sessionID]`; push the new entry
    /// into those mirrors so the chat UI shows the queued row immediately,
    /// matching the macOS enqueue path.
    func appendToWindowQueueMirrors(sessionID: String, message: QueuedMessage) {
        for window in registeredWindows() where window.currentSessionId == sessionID {
            if !window.messageQueue.contains(where: { $0.id == message.id }) {
                window.messageQueue.append(message)
            }
            var mirror = window.draftQueues[sessionID] ?? []
            if !mirror.contains(where: { $0.id == message.id }) {
                mirror.append(message)
            }
            window.draftQueues[sessionID] = mirror
        }
    }

    /// macOS windows hold an in-memory mirror of the queue in `messageQueue` and
    /// in `draftQueues[sessionID]`. When AppState pops an entry from threadStore
    /// (auto-flush or remote remove), drop it from every registered window so
    /// the UI doesn't show a phantom queued row.
    func evictFromWindowQueueMirrors(sessionID: String, queuedID: UUID) {
        for window in registeredWindows() {
            if window.currentSessionId == sessionID {
                window.messageQueue.removeAll { $0.id == queuedID }
            }
            // Inactive threads also retain a queue that is restored on navigation.
            if var mirror = window.draftQueues[sessionID] {
                mirror.removeAll { $0.id == queuedID }
                if mirror.isEmpty {
                    window.draftQueues.removeValue(forKey: sessionID)
                } else {
                    window.draftQueues[sessionID] = mirror
                }
            }
        }
    }

    func createMobilePlaceholderSession(project: Project, requestID: UUID) -> String {
        let sessionID = "pending-mobile-\(requestID.uuidString)"
        if allSessionSummaries.contains(where: { $0.id == sessionID }) {
            return sessionID
        }

        let selection = defaultModelSelection(for: project)
        let session = ChatSession(
            id: sessionID,
            projectId: project.id,
            title: ChatSession.defaultTitle,
            agentProvider: selection.provider,
            model: selection.model,
            origin: selection.provider.defaultSessionOrigin
        )
        allSessionSummaries.insert(session.summary, at: 0)
        threadStore.upsert(session.summary)
        updateState(sessionID) { state in
            state.agentProvider = selection.provider
            state.model = selection.model
        }
        return sessionID
    }

    func updateMobilePlaceholderTitleIfNeeded(sessionID: String, firstUserMessage: String) {
        guard let index = allSessionSummaries.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = allSessionSummaries[index]
        guard current.title == ChatSession.defaultTitle || current.title.isEmpty else { return }
        allSessionSummaries[index].title = ChatSession.placeholderTitle(from: firstUserMessage)
        allSessionSummaries[index].updatedAt = Date()
        threadStore.upsert(allSessionSummaries[index])
    }

}
