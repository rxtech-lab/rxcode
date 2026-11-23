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
        /// The turn's effort after checking it against the provider's own
        /// levels. Nil means "the agent's default" — either nothing was
        /// selected, or what was selected is not a level this agent accepts.
        var resolvedEffort: String?
        var resolvedSendMode: PermissionMode
        var earlyStream: AsyncStream<StreamEvent>?
        /// The same MCP servers as the three rendered fields above, unrendered.
        /// Backends that render their own config read these instead.
        var mcpRecords: [MCPServerRecord] = []
        var ideBridgeCommand: MCPBridgeCommand?
    }

    static func taskProgressPromptContext(for provider: AgentProvider, hasIDEBridge: Bool, planMode: Bool) -> String {
        let toolGuidance: String
        switch provider {
        case .flowcy:
            return ""
        case .claudeCode where !hasIDEBridge:
            toolGuidance = "Use Claude Code’s native todo tools, `TaskCreate` and `TaskUpdate` or `TodoWrite`, whichever is available."
        case .codex where planMode || !hasIDEBridge:
            toolGuidance = "Use Codex’s `update_plan` tool to track the checklist."
        case .localAgent where !hasIDEBridge:
            toolGuidance = "Use the native `todowrite` tool to track the checklist."
        case .acp where !hasIDEBridge:
            toolGuidance = "Use the client’s native todo or plan tool when available."
        case .claudeCode, .codex, .localAgent, .acp:
            let toolName = provider == .claudeCode ? "mcp__rxcode-ide__ide__set_todos" : "ide__set_todos"
            toolGuidance = """
            Use the RxCode IDE tool `\(toolName)` when available. Send the full `todos` array on every update \
            with `content` and `status` for each step. Use `pending`, `in_progress`, and `completed`.
            """
        }

        return """
        # Task progress

        When a task has more than two steps, create a short checklist before starting the work and keep it current. \
        Mark steps in progress when they start and completed when they are done. Keep one checklist and leave its \
        final status visible. \(toolGuidance)

        If work is unfinished, continue until the request is complete within the current mode, the user asks you to \
        stop, or a blocker requires their input or approval. Keep blocked or unfinished steps open and explain the blocker.
        """
    }

    /// Runs the expensive, independent pre-spawn work (memory lookup,
    /// IDE-MCP port allocation, skill-context resolution,
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
        effort: String?,
        permissionMode: PermissionMode,
        registerMode: PermissionMode,
        projectId: UUID,
        includeIDEMCP: Bool,
        includePriorContext: Bool = true,
        streamStart: Date
    ) async -> StreamPreflight {
        if projectId == Project.globalChatID {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                }.value
            } catch {
                let message = "Could not prepare the chat folder: \(error.localizedDescription)"
                return StreamPreflight(
                    mcpCodexOverrides: [], acpMCPServers: [], resolvedPrompt: prompt, resolvedModel: model,
                    resolvedEffort: nil, resolvedSendMode: permissionMode,
                    earlyStream: AsyncStream { continuation in
                        continuation.yield(.user(UserMessage(toolUseId: nil, content: message, isError: true)))
                        continuation.yield(.result(ResultEvent(
                            durationMs: nil, totalCostUsd: nil, sessionId: cliSessionId ?? sessionKey,
                            isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                        )))
                        continuation.finish()
                    }
                )
            }
        }
        // Flowcy declares its desktop terminal directly in the HTTPS chat request.
        if agentProvider == .flowcy {
            return StreamPreflight(
                mcpCodexOverrides: [], acpMCPServers: [], resolvedPrompt: prompt, resolvedModel: model,
                resolvedEffort: nil, resolvedSendMode: permissionMode
            )
        }

        // Resolve per-backend send-request fields (MCP injection, ACP client
        // spec, model split) before dispatching through the unified protocol.
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
        // Memory lookup, IDE-MCP port allocation, and
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
        let memoryActive = includePriorContext && memoryEnabled && memoryInjectEnabled
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
        async let idePortAsync: UInt16? = shouldIncludeIDEMCP
            ? ideMCPServer.allocate(
                sessionKey: capturedSessionKey,
                capabilities: agentProvider.staticCapabilities
            )
            : nil
        async let skillContextAsync = shouldIncludeIDEMCP ? marketplace.promptContext(for: agentProvider) : ""
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

        let configuredPromptContext = Self.configuredPromptContext(
            global: UserDefaults.standard.string(forKey: "globalAgentPrompt"),
            project: projects.first(where: { $0.id == projectId })?.customPrompt
        )

        // The IDE-MCP port is provider-agnostic at allocation time — the
        // bridge command is built from the port. Per-backend MCP config
        // writes still happen serially after this since they consume the
        // bridge, but they no longer block memory or skill resolution.
        let idePort = await idePortAsync
        let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
        logPreflight(
            "ideMCP",
            detail: "enabled=\(shouldIncludeIDEMCP) port=\(idePort.map(String.init) ?? "<nil>")"
        )
        let briefingContext = includePriorContext ? projectBriefingSystemPrompt(projectId: projectId, canFetchDetails: bridge != nil) : ""
        logPreflight("projectBriefing", detail: "contextChars=\(briefingContext.count)")
        let skillContext = bridge != nil ? await skillContextAsync : ""
        logPreflight("skillContext", detail: "chars=\(skillContext.count)")
        // Session-start hooks fire once, only for a brand-new thread (no resumed
        // CLI session). Their stdout is injected into this turn's agent context
        // alongside the briefing and memory context, and the status
        // cards inserted by UserAddedHook persist via the `.result` save.
        //
        // Project-new-chat hooks update passive banners and are driven by the
        // visible chat views. Keep them out of this preflight path: awaiting
        // network-backed banner checks here delays the first backend event.
        var hookStartContext = ""
        if includePriorContext, cliSessionId == nil, let project = projects.first(where: { $0.id == projectId }) {
            hookStartContext = await hookManager.dispatchSessionStart(
                SessionStartPayload(project: project, sessionKey: sessionKey)
            ).combinedOutput
            logPreflight("hooksStart", detail: "contextChars=\(hookStartContext.count)")
        }

        let mcpClaudeConfigPath = agentProvider == .claudeCode
            ? await mcp.writeClaudeConfig(projectPath: cwd, bridgeCommand: bridge)
            : nil
        let taskProgressContext = Self.taskProgressPromptContext(
            for: agentProvider,
            hasIDEBridge: bridge != nil && (agentProvider != .claudeCode || mcpClaudeConfigPath != nil),
            planMode: permissionMode == .plan
        )
        let codexAndACPContext = [
            taskProgressContext, skillContext, configuredPromptContext, briefingContext, resolvedMemoryContext, hookStartContext,
        ]
        switch agentProvider {
        case .claudeCode:
            logPreflight("claudeMCP", detail: "hasConfig=\(mcpClaudeConfigPath != nil)")
            appendExtraSystemPrompt(taskProgressContext)
            appendExtraSystemPrompt(configuredPromptContext)
            appendExtraSystemPrompt(briefingContext)
            appendExtraSystemPrompt(resolvedMemoryContext)
            appendExtraSystemPrompt(hookStartContext)
            appendExtraSystemPrompt(skillContext)
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
            resolvedPrompt = Self.promptWithBackgroundContext(codexAndACPContext, prompt: resolvedPrompt)
            resolvedSendMode = registerMode
        case .flowcy:
            break // Handled before local preflight.
        case .localAgent:
            // The harness renders one system prompt per turn, so background
            // context goes there rather than into the user's message.
            if localModels.model(id: resolvedModel)?.studioKind.isStudio == false {
                appendExtraSystemPrompt(taskProgressContext)
            }
            appendExtraSystemPrompt(configuredPromptContext)
            appendExtraSystemPrompt(briefingContext)
            appendExtraSystemPrompt(resolvedMemoryContext)
            appendExtraSystemPrompt(hookStartContext)
            appendExtraSystemPrompt(skillContext)
            resolvedSendMode = registerMode
            if !localModels.isAvailable {
                earlyStream = AsyncStream<StreamEvent> { c in
                    c.yield(.user(UserMessage(
                        toolUseId: nil,
                        content: "No local model is installed. Download one in Settings → Agent → RxCode Agent.",
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
        case .acp:
            acpMCPServers = await mcp.acpMCPServers(
                projectPath: cwd,
                bridgeCommand: bridge
            )
            logPreflight("acpMCP", detail: "servers=\(acpMCPServers.count)")
            resolvedPrompt = Self.promptWithBackgroundContext(codexAndACPContext, prompt: resolvedPrompt)
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
                        content: "No ACP client configured. Add one in Settings → Agent.",
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
            // The single guard for every send path — foreground, queued,
            // cross-project and MCP-driven turns all funnel through here.
            resolvedEffort: await sanitizedEffort(effort, for: agentProvider, model: resolvedModel),
            resolvedSendMode: resolvedSendMode,
            earlyStream: earlyStream,
            // Unrendered, for backends that build their own config. The
            // provider switch above writes the same servers into the three
            // rendered fields; these are the source those were rendered from.
            mcpRecords: await mcp.enabledServerRecords(projectPath: cwd),
            ideBridgeCommand: bridge.map { MCPBridgeCommand(command: $0.command, args: $0.args) }
        )
    }
}
