import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    /// Resolved, per-backend send-request fields produced by the pre-spawn
    /// preflight (MCP injection, ACP client spec, model split, background
    /// context) before dispatching through the unified backend protocol.
    struct StreamPreflight {
        var mcpClaudeConfigPath: String?
        var extraSystemPrompt: String?
        var mcpCodexOverrides: [String]
        var acpMCPServers: [JSONValue]
        var acpSpec: ACPClientSpec?
        var resolvedPrompt: String
        var resolvedModel: String?
        var resolvedSendMode: PermissionMode
        var earlyStream: AsyncStream<StreamEvent>?
    }

    /// Runs the expensive, independent pre-spawn work (memory lookup, git
    /// branch + briefing, IDE-MCP port allocation, skill-context resolution,
    /// session-start hooks) concurrently, then resolves the per-backend
    /// send-request fields. Reads `sessionKey` but never mutates it — the
    /// caller owns the `var sessionKey` used by the event loop.
    func resolveStreamPreflight(
        streamId: UUID,
        prompt: String,
        cwd: String,
        cliSessionId: String?,
        sessionKey: String,
        agentProvider: AgentProvider,
        model: String?,
        permissionMode: PermissionMode,
        registerMode: PermissionMode,
        projectId: UUID,
        includeIDEMCP: Bool,
        streamStart: Date
    ) async -> StreamPreflight {
        // Resolve per-backend send-request fields (MCP injection, ACP client
        // spec, model split) before dispatching through the unified protocol.
        var mcpClaudeConfigPath: String? = nil
        var extraSystemPrompt: String? = nil
        var mcpCodexOverrides: [String] = []
        var acpMCPServers: [JSONValue] = []
        var acpSpec: ACPClientSpec? = nil
        var resolvedPrompt = prompt
        var resolvedModel: String? = model
        var resolvedSendMode: PermissionMode = permissionMode
        var earlyStream: AsyncStream<StreamEvent>? = nil

        func appendExtraSystemPrompt(_ context: String) {
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let existing = extraSystemPrompt, !existing.isEmpty {
                extraSystemPrompt = "\(existing)\n\n\(trimmed)"
            } else {
                extraSystemPrompt = trimmed
            }
        }

        // Kick off the expensive, independent pre-spawn work concurrently.
        // Memory lookup, git branch + briefing, IDE-MCP port allocation, and
        // skill-context resolution all hop off MainActor and previously ran
        // stacked serially — pushing the first stream event well after the
        // user pressed send. Each `async let` starts immediately and is only
        // joined when its value is read below.
        //
        // Snapshot the MainActor flags into locals first: `async let` evaluates
        // the right-hand side in a nonisolated autoclosure, so it can't read
        // `memoryEnabled` / `memoryInjectEnabled` / `memoryMaxContextItems`
        // directly. The local `let` capture solves both isolation and the
        // "captured var" warning for `sessionKey`.
        let memoryActive = memoryEnabled && memoryInjectEnabled
        let memoryLimit = memoryMaxContextItems
        let memoryMode = memoryRetrievalMode
        let memoryMinScore = memoryInjectionScoreThreshold
        let capturedSessionKey = sessionKey
        let memoryService = self.memoryService
        let marketplace = self.marketplace
        let ideMCPServer = self.ideMCPServer
        let shouldIncludeIDEMCP = includeIDEMCP

        func logPreflight(_ label: String, detail: String = "") {
            let elapsed = Date().timeIntervalSince(streamStart)
            if detail.isEmpty {
                logger.info("[Stream:UI] preflight \(label, privacy: .public) stream=\(streamId) after=\(String(format: "%.2f", elapsed), privacy: .public)s")
            } else {
                logger.info("[Stream:UI] preflight \(label, privacy: .public) stream=\(streamId) after=\(String(format: "%.2f", elapsed), privacy: .public)s \(detail, privacy: .public)")
            }
        }

        async let memoryHitsAsync = memoryActive
            ? await memoryService.search(
                prompt,
                projectId: projectId,
                limit: memoryLimit,
                minScore: memoryMinScore
            )
            : []
        async let currentBranchAsync = GitHelper.currentBranch(at: cwd)
        async let idePortAsync: UInt16? = shouldIncludeIDEMCP
            ? ideMCPServer.allocate(
                sessionKey: capturedSessionKey,
                capabilities: agentProvider.staticCapabilities
            )
            : nil
        async let skillContextAsync: String? = marketplace.promptContext(for: agentProvider)
        async let codexSkillOverridesAsync: [String] = shouldIncludeIDEMCP && agentProvider == .codex
            ? await marketplace.codexConfigOverrides()
            : []

        let resolvedMemoryContext: String
        let memoryHitCount: Int
        if memoryActive {
            let hits = await memoryHitsAsync
            memoryHitCount = hits.count
            resolvedMemoryContext = memoryContextSystemPrompt(relatedHits: hits)
        } else {
            memoryHitCount = 0
            resolvedMemoryContext = ""
        }
        logPreflight(
            "memory",
            detail: "enabled=\(memoryActive) mode=\(memoryMode.title) minScore=\(String(format: "%.2f", memoryMinScore)) hits=\(memoryHitCount) contextChars=\(resolvedMemoryContext.count)"
        )

        let branchBriefingContext: String
        if let branch = await currentBranchAsync,
           let briefing = threadStore.branchBriefingItem(projectId: projectId, branch: branch) {
            branchBriefingContext = Self.branchBriefingSystemPrompt(
                branch: branch,
                briefing: briefing.briefing
            )
            logPreflight("branchBriefing", detail: "branch=\(branch) contextChars=\(branchBriefingContext.count)")
        } else {
            branchBriefingContext = ""
            logPreflight("branchBriefing", detail: "contextChars=0")
        }

        // The IDE-MCP port is provider-agnostic at allocation time — the
        // bridge command is built from the port. Per-backend MCP config
        // writes still happen serially after this since they consume the
        // bridge, but they no longer block memory/git/skill resolution.
        let idePort = await idePortAsync
        let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
        logPreflight(
            "ideMCP",
            detail: "enabled=\(shouldIncludeIDEMCP) port=\(idePort.map(String.init) ?? "<nil>")"
        )

        // Session-start hooks fire once, only for a brand-new thread (no resumed
        // CLI session). Their stdout is injected into this turn's agent context
        // the same way the branch briefing / memory context is, and the status
        // cards inserted by UserAddedHook persist via the `.result` save.
        //
        // Project-new-chat hooks update passive banners and are driven by the
        // visible chat views. Keep them out of this preflight path: awaiting
        // network-backed banner checks here delays the first backend event.
        var hookStartContext = ""
        if cliSessionId == nil, let project = projects.first(where: { $0.id == projectId }) {
            hookStartContext = await hookManager.dispatchSessionStart(
                SessionStartPayload(project: project, sessionKey: sessionKey)
            ).combinedOutput
            logPreflight("hooksStart", detail: "contextChars=\(hookStartContext.count)")
        }

        switch agentProvider {
        case .claudeCode:
            mcpClaudeConfigPath = await mcp.writeClaudeConfig(projectPath: cwd, bridgeCommand: bridge)
            logPreflight("claudeMCP", detail: "hasConfig=\(mcpClaudeConfigPath != nil)")
            // Surface the accumulated briefing for the project's current branch
            // to the agent as background context via `--append-system-prompt`.
            appendExtraSystemPrompt(branchBriefingContext)
            appendExtraSystemPrompt(resolvedMemoryContext)
            appendExtraSystemPrompt(hookStartContext)
            if let skillContext = await skillContextAsync {
                logPreflight("skillContext", detail: "chars=\(skillContext.count)")
                appendExtraSystemPrompt(skillContext)
            } else {
                logPreflight("skillContext", detail: "chars=0")
            }
        case .codex:
            mcpCodexOverrides = await mcp.codexConfigOverrides(
                projectPath: cwd,
                bridgeCommand: bridge,
                disableAllServers: !shouldIncludeIDEMCP
            )
            if !shouldIncludeIDEMCP {
                mcpCodexOverrides += ["--disable", "plugins"]
            }
            logPreflight(
                "codexMCP",
                detail: "args=\(mcpCodexOverrides.count) disabledAll=\(!shouldIncludeIDEMCP)"
            )
            let codexSkillOverrides = await codexSkillOverridesAsync
            logPreflight("codexSkillOverrides", detail: "args=\(codexSkillOverrides.count)")
            mcpCodexOverrides += codexSkillOverrides
            resolvedPrompt = Self.promptWithBackgroundContext(
                [branchBriefingContext, resolvedMemoryContext, hookStartContext],
                prompt: resolvedPrompt
            )
            if let skillContext = await skillContextAsync {
                logPreflight("skillContext", detail: "chars=\(skillContext.count)")
                resolvedPrompt = "\(skillContext)\n\nUser request:\n\(resolvedPrompt)"
            } else {
                logPreflight("skillContext", detail: "chars=0")
            }
            resolvedSendMode = registerMode
        case .acp:
            acpMCPServers = await mcp.acpMCPServers(
                projectPath: cwd,
                bridgeCommand: bridge
            )
            logPreflight("acpMCP", detail: "servers=\(acpMCPServers.count)")
            resolvedPrompt = Self.promptWithBackgroundContext(
                [branchBriefingContext, resolvedMemoryContext, hookStartContext],
                prompt: resolvedPrompt
            )
            if let skillContext = await skillContextAsync {
                logPreflight("skillContext", detail: "chars=\(skillContext.count)")
                resolvedPrompt = "\(skillContext)\n\nUser request:\n\(resolvedPrompt)"
            } else {
                logPreflight("skillContext", detail: "chars=0")
            }
            // `model` may be a composite `<clientId>::<model>` key (from the picker)
            // or a bare model id (from a per-session override).
            let split = acpSelectionParts(for: model)
            let resolvedClientId = split?.clientId
                ?? sessionStates[sessionKey]?.acpClientId
                ?? selectedACPClientId
            resolvedModel = split?.model ?? model
            resolvedSendMode = registerMode
            if let spec = acpClients.first(where: { $0.id == resolvedClientId && $0.enabled }) {
                acpSpec = spec
            } else {
                logger.error("[ACP] no enabled client for id=\(resolvedClientId, privacy: .public)")
                earlyStream = AsyncStream<StreamEvent> { c in
                    c.yield(.user(UserMessage(
                        toolUseId: nil,
                        content: "No ACP client configured. Add one in Settings → ACP Clients.",
                        isError: true
                    )))
                    c.yield(.result(ResultEvent(
                        durationMs: nil, totalCostUsd: nil,
                        sessionId: cliSessionId ?? sessionKey,
                        isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                    )))
                    c.finish()
                }
            }
        }

        return StreamPreflight(
            mcpClaudeConfigPath: mcpClaudeConfigPath,
            extraSystemPrompt: extraSystemPrompt,
            mcpCodexOverrides: mcpCodexOverrides,
            acpMCPServers: acpMCPServers,
            acpSpec: acpSpec,
            resolvedPrompt: resolvedPrompt,
            resolvedModel: resolvedModel,
            resolvedSendMode: resolvedSendMode,
            earlyStream: earlyStream
        )
    }
}
