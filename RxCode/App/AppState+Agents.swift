import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Memory

    func allMemoryItems() async -> [MemoryItem] {
        await memoryService.allMemories()
    }

    func searchMemoryItems(query: String, projectId: UUID? = nil, limit: Int = 50) async -> [MemoryService.Hit] {
        await memoryService.search(query, projectId: projectId, limit: limit)
    }

    @discardableResult
    func addMemoryItem(content: String, projectId: UUID?, kind: String = "fact", scope: String = "project") async -> MemoryItem? {
        guard memoryEnabled else { return nil }
        let item = await memoryService.addMemory(
            content: content,
            projectId: scope == "global" ? nil : projectId,
            sessionId: nil,
            sourceMessageId: nil,
            kind: normalizedMemoryKind(kind),
            scope: normalizedMemoryScope(scope)
        )
        if item != nil { memoryRevision &+= 1 }
        return item
    }

    @discardableResult
    func updateMemoryItem(id: String, content: String, projectId: UUID?, kind: String, scope: String) async -> MemoryItem? {
        guard memoryEnabled else { return nil }
        let item = await memoryService.updateMemory(
            id: id,
            content: content,
            projectId: scope == "global" ? nil : projectId,
            sessionId: nil,
            sourceMessageId: nil,
            kind: normalizedMemoryKind(kind),
            scope: normalizedMemoryScope(scope)
        )
        if item != nil { memoryRevision &+= 1 }
        return item
    }

    func deleteMemoryItem(id: String) async {
        await memoryService.deleteMemory(id: id)
        memoryRevision &+= 1
    }

    func deleteAllMemoryItems(projectId: UUID? = nil) async {
        await memoryService.deleteAll(projectId: projectId)
        memoryRevision &+= 1
    }

    func memoryContextSystemPrompt(relatedHits: [MemoryService.Hit]) -> String {
        guard memoryEnabled, memoryInjectEnabled, !relatedHits.isEmpty else { return "" }

        let relatedLines = relatedHits
            .prefix(memoryMaxContextItems)
            .enumerated()
            .map { idx, hit in
                "\(idx + 1). \(hit.item.content)"
            }
            .joined(separator: "\n")

        return """
        # Relevant user memory

        The notes below are durable user/project memories saved locally in RxCode. Use them as background context for this turn. They may be incomplete or stale; the current user message still has priority.

        Related memories for this turn:
        \(relatedLines)
        """
    }

    func memoryContextPromptPrefix(for context: String, prompt: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        return """
        \(trimmed)

        User request:
        \(prompt)
        """
    }

    func scheduleMemoryExtraction(
        sessionId: String,
        projectId: UUID,
        messages: [ChatMessage]
    ) {
        guard memoryEnabled, memoryAutoCreateEnabled else { return }
        let userMessages = userMessageTexts(in: messages)
        guard !userMessages.isEmpty else { return }
        let sourceMessageId = messages.last(where: { $0.role == .user && !$0.isError })?.id
        let summary = allSessionSummaries.first(where: { $0.id == sessionId })
            ?? summaryFor(sessionId: sessionId, projectId: projectId)

        Task { [weak self] in
            guard let self else { return }
            await self.extractAndStoreMemories(
                sessionId: sessionId,
                projectId: projectId,
                sourceMessageId: sourceMessageId,
                userMessages: userMessages,
                summary: summary
            )
        }
    }

    func extractAndStoreMemories(
        sessionId: String,
        projectId: UUID,
        sourceMessageId: UUID?,
        userMessages: [String],
        summary: ChatSession.Summary
    ) async {
        let memorySource = userMessages.joined(separator: "\n\n")
        let relatedHits = await memoryService.search(
            memorySource,
            projectId: projectId,
            limit: 6
        )
        let related = relatedHits.map { (id: $0.item.id, content: $0.item.content) }
        guard let raw = await generateMemoryOperations(
            existingMemories: related,
            userMessages: userMessages,
            summary: summary
        ) else { return }
        let operations = Self.parseMemoryOperations(raw)
        guard !operations.isEmpty else { return }

        var changed = false
        for operation in operations {
            switch operation.action {
            case "add":
                guard let content = operation.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { continue }
                let scope = normalizedMemoryScope(operation.scope)
                let existing = await memoryService.search(content, projectId: projectId, limit: 1)
                if let best = existing.first, best.score > 0.94 { continue }
                if await memoryService.addMemory(
                    content: content,
                    projectId: scope == "global" ? nil : projectId,
                    sessionId: sessionId,
                    sourceMessageId: sourceMessageId,
                    kind: normalizedMemoryKind(operation.kind),
                    scope: scope
                ) != nil {
                    changed = true
                }
            case "update":
                guard let id = operation.id,
                      let content = operation.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { continue }
                let scope = normalizedMemoryScope(operation.scope)
                if await memoryService.updateMemory(
                    id: id,
                    content: content,
                    projectId: scope == "global" ? nil : projectId,
                    sessionId: sessionId,
                    sourceMessageId: sourceMessageId,
                    kind: normalizedMemoryKind(operation.kind),
                    scope: scope
                ) != nil {
                    changed = true
                }
            case "delete":
                guard let id = operation.id else { continue }
                await memoryService.deleteMemory(id: id)
                changed = true
            default:
                continue
            }
        }
        if changed {
            memoryRevision &+= 1
        }
    }

    struct MemoryOperation {
        let action: String
        let id: String?
        let content: String?
        let kind: String?
        let scope: String?
    }

    static func parseMemoryOperations(_ raw: String) -> [MemoryOperation] {
        let trimmed = stripJSONFence(raw)
        guard let range = jsonArrayRange(in: trimmed) else { return [] }
        let json = String(trimmed[range])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { entry in
            guard let action = entry["action"] as? String else { return nil }
            return MemoryOperation(
                action: action.lowercased(),
                id: entry["id"] as? String,
                content: entry["content"] as? String,
                kind: entry["kind"] as? String,
                scope: entry["scope"] as? String
            )
        }
    }

    static func stripJSONFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func jsonArrayRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start <= end else { return nil }
        return start..<text.index(after: end)
    }

    func normalizedMemoryKind(_ value: String?) -> String {
        switch value?.lowercased() {
        case "preference", "decision", "fact":
            return value!.lowercased()
        default:
            return "fact"
        }
    }

    func normalizedMemoryScope(_ value: String?) -> String {
        value?.lowercased() == "global" ? "global" : "project"
    }

    // MARK: - Agent Backends

    /// Looks up the `AgentBackend` for the given provider. Used by
    /// `processStream`/`cancel`/`finalize` to dispatch via the unified
    /// protocol instead of switching on the enum directly. Tests can
    /// populate `agentBackendOverrides` to substitute a mock for any
    /// provider; production code never sets this.
    func backend(for provider: AgentProvider) -> any AgentBackend {
        if let override = agentBackendOverrides[provider] { return override }
        switch provider {
        case .claudeCode: return claude
        case .codex: return codex
        case .acp: return acp
        }
    }

    // MARK: - ACP Actions

    func loadACPClientsFromDisk() async {
        let loaded = await persistence.loadACPClients()
        acpClients = loaded
    }

    func saveACPClients() {
        let clients = acpClients
        Task { [persistence] in
            try? await persistence.saveACPClients(clients)
        }
    }

    func refreshACPRegistry(forceRefresh: Bool = false) async {
        acpRegistryLoading = true
        defer { acpRegistryLoading = false }
        let snapshotURL = persistence.acpRegistrySnapshotURL()
        if let reg = await acpRegistryService.fetchRegistry(forceRefresh: forceRefresh, snapshotURL: snapshotURL) {
            acpRegistry = reg
        }
    }

    func addACPClient(_ spec: ACPClientSpec) {
        acpClients.append(spec)
        saveACPClients()
    }

    func updateACPClient(_ spec: ACPClientSpec) {
        guard let idx = acpClients.firstIndex(where: { $0.id == spec.id }) else { return }
        acpClients[idx] = spec
        saveACPClients()
    }

    func removeACPClient(id: String) {
        if let removed = acpClients.first(where: { $0.id == id }) {
            // Clean up the on-disk install if this client owns a binary
            // under the installer's managed root.
            if case .binary(let path, _, _) = removed.launch,
               let registryId = removed.registryId,
               ACPInstallerService.isManaged(path: path)
            {
                Task.detached { await ACPInstallerService.shared.uninstall(registryId: registryId) }
            }
        }
        acpClients.removeAll { $0.id == id }
        if selectedACPClientId == id { selectedACPClientId = "" }
        saveACPClients()
    }

    /// Installs an ACP client from a registry entry. Tries the platform's
    /// declared binary distribution first (downloading and extracting it),
    /// then falls back to whatever else the registry declares (`npx`/`uvx`).
    /// After install, probes the agent (`initialize` + `session/new`) to
    /// populate the model picker from its advertised `configOptions`.
    func installACPClient(from agent: ACPRegistryAgent) async throws -> ACPClientSpec {
        let launch = try await resolveLaunch(for: agent)
        let spec = ACPClientSpec(
            registryId: agent.id,
            displayName: agent.name,
            launch: launch,
            iconURL: agent.icon
        )
        return await probedSpec(spec, agentId: agent.id)
    }

    /// Re-probes an installed client and persists the result. If the probe
    /// fails or the agent doesn't expose a model selector, the picker falls
    /// back to the built-in defaults for known registry agents.
    func refreshACPClientModels(id: String) async {
        guard let idx = acpClients.firstIndex(where: { $0.id == id }) else { return }
        let current = acpClients[idx]
        let updated = await probedSpec(current, agentId: current.registryId ?? current.id)
        if let liveIdx = acpClients.firstIndex(where: { $0.id == id }) {
            acpClients[liveIdx] = updated
            saveACPClients()
        }
    }

    func probedSpec(_ spec: ACPClientSpec, agentId: String) async -> ACPClientSpec {
        var result = spec
        let probeCwd = NSHomeDirectory()
        do {
            if let config = try await acp.probeModels(spec: spec, cwd: probeCwd) {
                result.modelConfigId = config.configId
                result.models = config.options.map { $0.value }
                result.modelOptions = config.options
                logger.info("[ACP] probed \(result.models.count) models from \(agentId, privacy: .public) configId=\(config.configId, privacy: .public) current=\(config.currentValue ?? "nil", privacy: .public) models=[\(Self.acpModelListDescription(config.options), privacy: .public)]")
                return result
            }
            logger.info("[ACP] no model selector advertised by \(agentId, privacy: .public)")
        } catch {
            logger.warning("[ACP] model probe failed for \(agentId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Probe missed — leave the model list empty. The picker injects a
        // synthetic "Default" entry so the client is still selectable; the
        // agent uses whatever model it chooses internally.
        result.modelConfigId = nil
        result.models = []
        result.modelOptions = nil
        return result
    }

    /// Writes a freshly-discovered model list back to the matching client
    /// spec. Called from the stream loop whenever `session/new` advertises
    /// a model selector — keeps the picker in sync with what the agent
    /// actually supports without requiring a settings round-trip.
    func applyDiscoveredACPModels(clientId: String, config: ACPModelConfig) {
        guard let idx = acpClients.firstIndex(where: { $0.id == clientId }) else { return }
        let newModels = config.options.map { $0.value }
        var updated = acpClients[idx]
        logger.info("[ACP] applying discovered models clientId=\(clientId, privacy: .public) configId=\(config.configId, privacy: .public) current=\(config.currentValue ?? "nil", privacy: .public) models=\(newModels.count) [\(Self.acpModelListDescription(config.options), privacy: .public)]")
        guard updated.models != newModels || updated.modelOptions != config.options || updated.modelConfigId != config.configId else {
            logger.info("[ACP] discovered models unchanged for clientId=\(clientId, privacy: .public)")
            return
        }
        updated.models = newModels
        updated.modelOptions = config.options
        updated.modelConfigId = config.configId
        acpClients[idx] = updated
        saveACPClients()
    }

    static func acpModelListDescription(_ options: [ACPModelOption]) -> String {
        options.map { option in
            option.name == option.value ? option.value : "\(option.value) (\(option.name))"
        }.joined(separator: ", ")
    }

    func resolveLaunch(for agent: ACPRegistryAgent) async throws -> ACPClientSpec.LaunchKind {
        // Prefer the platform binary; on download/extract failure, fall through.
        if let bin = agent.distribution.binary?[ACPPlatform.current] {
            do {
                let path = try await ACPInstallerService.shared.install(
                    bin, registryId: agent.id, version: agent.version
                )
                return .binary(path: path, args: bin.args ?? [], env: bin.env ?? [:])
            } catch {
                if let npx = agent.distribution.npx {
                    return .npx(package: npx.package, args: npx.args ?? [], env: npx.env ?? [:])
                }
                if let uvx = agent.distribution.uvx {
                    return .uvx(package: uvx.package, args: uvx.args ?? [], env: uvx.env ?? [:])
                }
                throw error
            }
        }
        if let npx = agent.distribution.npx {
            return .npx(package: npx.package, args: npx.args ?? [], env: npx.env ?? [:])
        }
        if let uvx = agent.distribution.uvx {
            return .uvx(package: uvx.package, args: uvx.args ?? [], env: uvx.env ?? [:])
        }
        throw ACPInstallError.noCompatibleDistribution
    }

    // MARK: - MCP Actions

    func refreshMCPServers() async {
        mcpIsLoading = true
        mcpListError = nil
        defer { mcpIsLoading = false }
        do {
            // Pass the active project so Settings can show global defaults plus
            // the effective per-project override state.
            let list = try await mcp.list(projectPath: activeProjectPath)
            // Preserve last-known status for rows that already exist so a list
            // refresh doesn't visually downgrade everything to .unknown.
            var merged: [MCPServerInfo] = []
            merged.reserveCapacity(list.count)
            for info in list {
                if let existing = mcpServers.first(where: { $0.id == info.id }) {
                    merged.append(MCPServerInfo(
                        name: info.name,
                        transport: info.transport,
                        endpoint: info.endpoint,
                        status: existing.status,
                        scope: info.scope,
                        projectPath: info.projectPath,
                        isGloballyEnabled: info.isGloballyEnabled,
                        projectOverride: info.projectOverride,
                        effectiveEnabled: info.effectiveEnabled
                    ))
                } else {
                    merged.append(info)
                }
            }
            mcpServers = merged
        } catch {
            mcpListError = error.localizedDescription
            logger.error("MCP list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func probeMCPServer(name: String) async {
        guard let info = mcpServers.first(where: { $0.name == name }) else {
            // Fall back to a name-only probe if the row hasn't loaded yet.
            await probeMCPServer(id: name, name: name, lookup: { await self.mcp.probe(name: name, projectPath: self.activeProjectPath) })
            return
        }
        await probeMCPServer(info: info)
    }

    /// Probe one specific row. Use this when the same server name appears in
    /// multiple scopes/projects (aggregated Settings list) so the right
    /// configuration is resolved.
    func probeMCPServer(info: MCPServerInfo) async {
        await probeMCPServer(id: info.id, name: info.name, lookup: { await self.mcp.probe(info: info) })
    }

    func probeMCPServer(id: String, name: String, lookup: @escaping () async -> MCPProbeResult) async {
        guard !mcpInFlightProbes.contains(id) else { return }
        mcpInFlightProbes.insert(id)
        defer { mcpInFlightProbes.remove(id) }

        let previousStatus: MCPStatus? = mcpServers.first(where: { $0.id == id })?.status
        let result = await lookup()
        mcpProbeResults[id] = result

        let newStatus: MCPStatus = result.ok
            ? .connected
            : .failed(result.error ?? "Probe failed")

        if let idx = mcpServers.firstIndex(where: { $0.id == id }) {
            let row = mcpServers[idx]
            mcpServers[idx] = MCPServerInfo(
                name: row.name,
                transport: row.transport,
                endpoint: row.endpoint,
                status: newStatus,
                scope: row.scope,
                projectPath: row.projectPath,
                isGloballyEnabled: row.isGloballyEnabled,
                projectOverride: row.projectOverride,
                effectiveEnabled: row.effectiveEnabled
            )
        }

        // Disconnect notification: only fire on the connected→failed edge so we
        // don't spam the user on every failed re-probe.
        if case .connected = (previousStatus ?? .unknown),
           case .failed(let message) = newStatus
        {
            let serverName = name
            Task { @MainActor [weak self] in
                await self?.hookManager.dispatchMCPDisconnected(MCPDisconnectedPayload(name: serverName, error: message))
            }
        }
    }

    @discardableResult
    func addMCPServer(spec: MCPServerSpec, scope: MCPScope) async -> String? {
        do {
            try await mcp.add(spec: spec, scope: scope, projectPath: activeProjectPath)
            await refreshMCPServers()
            // Auto-probe on add so the new row shows live status and tool list
            // without the user clicking Test.
            await probeMCPServer(name: spec.name)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func removeMCPServer(name: String, scope: MCPScope) async -> String? {
        do {
            try await mcp.remove(name: name, scope: scope)
            // Clear the probe entry that belonged to the removed row. The id
            // shape is `<scope>:[<projectPath>:]<name>` — drop any whose name
            // suffix and scope prefix match what we just removed.
            let scopePrefix = "\(scope.rawValue):"
            mcpProbeResults = mcpProbeResults.filter { key, _ in
                !(key.hasPrefix(scopePrefix) && key.hasSuffix(":\(name)"))
            }
            await refreshMCPServers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func setMCPServerGlobalEnabled(name: String, enabled: Bool) async -> String? {
        do {
            try await mcp.setGlobalEnabled(name: name, enabled: enabled)
            await refreshMCPServers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func setMCPServerProjectOverride(name: String, override: MCPProjectOverride) async -> String? {
        guard let activeProjectPath else {
            return "No active project selected."
        }
        do {
            try await mcp.setProjectOverride(name: name, projectPath: activeProjectPath, override: override)
            await refreshMCPServers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Spawn the periodic MCP probe loop. Idempotent.
    func startMCPPeriodicProbe() {
        guard mcpPeriodicProbeTask == nil else { return }
        mcpPeriodicProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppState.mcpPeriodicProbeInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshAndProbeAllMCPServers()
            }
        }
    }

    /// Refresh the MCP server list and probe every server concurrently.
    /// Used at app launch (and on a 5-minute timer) so the Settings sheet shows
    /// live status without the user having to click "Test" on each row.
    func refreshAndProbeAllMCPServers() async {
        await refreshMCPServers()
        let snapshot = mcpServers
        guard !snapshot.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for info in snapshot {
                group.addTask { [weak self] in
                    await self?.probeMCPServer(info: info)
                }
            }
        }
    }

}
