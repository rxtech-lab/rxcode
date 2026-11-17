import AppKit
import Foundation
import os
import RxAgentClients
import RxAgentCore
import RxAgentVoice
import RxCodeCore

// MARK: - Voice Engine Construction, State Sync & Background Monitor

extension PetController {
    func buildVoiceSession(for mode: PetVoiceModeKind) async throws -> VoiceSession {
        guard let appState else {
            throw VoiceError.unavailable("No active RxCode workspace is open.")
        }

        let targetProject = resolveTargetProject(in: appState)
        let instructions = Self.buildVoiceSystemInstructions(appState: appState, targetProject: targetProject, configuration: configuration)

        switch mode {
        case .codexRealtime:
            let useWebRTC = configuration.codexTransport == .webRTC
            let passiveAudio = PassiveVoiceAudioDriver()
            passiveAudio.speechPlayback = speechPlayback
            let hwAudio = useWebRTC ? nil : PetVoiceAudioDriver(
                suppressesCaptureDuringPlayback: false,
                inputDeviceUID: configuration.microphoneDeviceUID,
                outputDeviceUID: configuration.speakerDeviceUID
            )

            var sessionRef: VoiceSession?
            let engine = PetCodexRealtimeEngine(
                prepareLaunch: { [weak self, weak appState] in
                    guard let self, let appState else { throw VoiceError.invalidState }
                    return try await self.prepareCodexRealtimeLaunch(appState: appState, project: targetProject)
                },
                releaseIDEMCP: { [weak appState] sessionKey in
                    await appState?.ideMCPServer.release(sessionKey: sessionKey)
                },
                onLevels: { [weak self] input, output in
                    Task { @MainActor [weak self] in
                        sessionRef?.meters.input = input
                        sessionRef?.meters.output = output
                        if useWebRTC, let self {
                            if sessionRef?.lifecycle == .active, sessionRef?.isMuted == false {
                                self.speechPlayback.updateRemoteLevel(output)
                            } else { self.speechPlayback.reset() }
                        }
                    }
                },
                onConnected: { [weak self] in
                    await self?.playVoiceConnectedSound()
                },
                onToolEvent: { [weak self] event in
                    await self?.handlePetToolEvent(event)
                },
                bindWebRTCMuteHandler: { [weak self] muteSetter in
                    Task { @MainActor [weak self] in
                        self?.realtimeToolCueMute = muteSetter
                        passiveAudio.onMuteChanged = { muted in
                            muteSetter(muted)
                        }
                    }
                }
            )

            switch await engine.readiness() {
            case .ready:
                break
            case .needsSetup(let msg), .needsDownload(let msg):
                throw VoiceError.unavailable(msg)
            }

            let driver: any VoiceAudioDriver = hwAudio.map { $0 as any VoiceAudioDriver } ?? passiveAudio
            let session = VoiceSession(
                engine: engine,
                audio: driver,
                config: VoiceSessionConfig(instructions: instructions)
            )
            hwAudio?.meters = session.meters
            hwAudio?.speechPlayback = speechPlayback
            sessionRef = session
            currentHardwareAudioDriver = hwAudio
            return session

        case .localPipeline:
            let hwAudio = PetVoiceAudioDriver(
                suppressesCaptureDuringPlayback: true,
                inputDeviceUID: configuration.microphoneDeviceUID,
                outputDeviceUID: configuration.speakerDeviceUID
            )
            let engine = PetStreamingPipelineVoiceEngine(
                recognizer: localRecognizer,
                synthesizer: localSynthesizer,
                responder: customAgentResponder,
                readinessCheck: { [weak self] in
                    guard let self else { return .needsSetup("Pet controller unavailable.") }
                    return await self.checkPipelineReadiness()
                }
            )

            switch await engine.readiness() {
            case .ready:
                break
            case .needsSetup(let msg), .needsDownload(let msg):
                throw VoiceError.unavailable(msg)
            }

            let session = VoiceSession(
                engine: engine,
                audio: hwAudio,
                config: VoiceSessionConfig(instructions: instructions)
            )
            hwAudio.meters = session.meters
            hwAudio.speechPlayback = speechPlayback
            currentHardwareAudioDriver = hwAudio
            return session
        }
    }

    func prepareCodexRealtimeLaunch(
        appState: AppState,
        project: Project?
    ) async throws -> PetCodexRealtimeEngine.LaunchParameters {
        let sessionKey = "pet-codex-realtime-\(UUID().uuidString.lowercased())"
        let cwdPath = project?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let idePort = await appState.ideMCPServer.allocate(
            sessionKey: sessionKey,
            capabilities: RxCodeCore.AgentProvider.codex.staticCapabilities
        )
        let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
        let rawPairs = await appState.mcp.codexConfigOverrides(
            projectPath: cwdPath,
            bridgeCommand: bridge,
            disableAllServers: false
        )
        let bareOverrides = CodexConfigOverrideParser.extractBareOverrides(from: rawPairs)
            + PetCodexRealtimeEngine.ideToolApprovalOverrides
        return PetCodexRealtimeEngine.LaunchParameters(
            workingDirectory: URL(fileURLWithPath: cwdPath),
            transportPreference: configuration.codexTransport,
            voice: configuration.resolvedCodexVoice.rawValue,
            model: configuration.codexRealtimeModel.isEmpty ? nil : configuration.codexRealtimeModel,
            configOverrides: bareOverrides,
            sessionKey: sessionKey,
            idePort: idePort,
            requestApproval: { [weak self, weak appState] params in
                guard let self, let appState else { return false }
                var details = ["reason", "command", "message"].compactMap { params[$0]?.stringValue }
                if let permissions = params["permissions"],
                   let data = try? JSONEncoder().encode(permissions),
                   let text = String(data: data, encoding: .utf8) {
                    details.append("Requested access: \(text)")
                }
                let fallback = String(data: (try? JSONEncoder().encode(params)) ?? Data(), encoding: .utf8)
                let request = ConfirmationTool.Request(
                    title: "Allow Companion Action?",
                    message: details.isEmpty ? fallback : details.joined(separator: "\n\n"),
                    confirmLabel: "Allow", cancelLabel: "Deny"
                )
                let petEnabled = await self.configuration.isEnabled
                if !petEnabled { await self.openCompanionWindow() }
                return await appState.requestAgentConfirmation(request, sessionKey: sessionKey)
            },
            onUserTurn: { [weak self] in
                await self?.hidePreviousToolCalls()
            }
        )
    }

    func prepareCustomAgentTurn(
        userText: String,
        resumeSessionID: String?,
        sessionKeyOverride: String? = nil,
        contextOverride: String? = nil,
        workingDirectoryOverride: URL? = nil,
        agentOverride: TaskAgentConfig? = nil,
        attachments: [AgentAttachment] = [],
        history: [AgentMessage] = []
    ) async throws -> PetCustomAgentResponder.ResolvedTurnSetup {
        guard let appState else {
            throw VoiceError.unavailable("No active RxCode workspace is available.")
        }

        let effectiveAgent = agentOverride ?? configuration.customAgent ?? appState.defaultTaskAgent()
        let provider = effectiveAgent.provider ?? appState.selectedAgentProvider
        var requestedModel = effectiveAgent.model
        let targetProject = resolveTargetProject(in: appState)
        let cwdPath = workingDirectoryOverride?.path ?? targetProject?.path ?? FileManager.default.homeDirectoryForCurrentUser.path

        let sessionKey: String
        if let sessionKeyOverride {
            sessionKey = sessionKeyOverride
        } else if let existing = activePipelineSessionKey {
            sessionKey = existing
        } else {
            let fresh = "pet-voice-\(UUID().uuidString.lowercased())"
            activePipelineSessionKey = fresh
            sessionKey = fresh
        }

        let idePort = await appState.ideMCPServer.allocate(
            sessionKey: sessionKey,
            capabilities: provider.staticCapabilities
        )
        let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
        let mcpRecords = await appState.mcp.enabledServerRecords(projectPath: cwdPath)
        var sdkMCPs: [RxAgentCore.MCPServerSpec] = []
        if let bridge {
            sdkMCPs.append(.stdio(name: "rxcode-ide", command: bridge.command, args: bridge.args))
        }
        sdkMCPs += mcpRecords.sorted { $0.name < $1.name }.compactMap(RxAgentCore.MCPServerSpec.init)

        let client: any RxAgentCore.AgentClient
        switch provider {
        case .claudeCode:
            client = ClaudeCodeClient()
        case .codex:
            client = CodexClient()
        case .acp:
            let split = appState.acpSelectionParts(for: requestedModel)
            let clientID = split?.clientId ?? appState.selectedACPClientId
            requestedModel = split?.model ?? requestedModel
            let chosenSpec = appState.acpClients.first { $0.id == clientID && $0.enabled }
                ?? appState.acpClients.first { $0.enabled }
            guard let spec = chosenSpec, let acpClient = SDKBackendFactory.makeACPClient(spec) else {
                throw VoiceError.unavailable("No enabled ACP client is configured. Add or enable one in Settings → Agent.")
            }
            client = acpClient
        case .localAgent:
            if requestedModel == nil || requestedModel?.isEmpty == true {
                requestedModel = appState.localModels.installed.first { !$0.studioKind.isStudio }?.id
            }
            let ideTools = IDEToolHarnessBridge.makeAllTools(
                capabilities: provider.staticCapabilities,
                sessionKeyProvider: { sessionKey },
                callHandler: { [weak appState] name, args, key in
                    guard let appState else { throw VoiceError.invalidState }
                    return try await appState.ideHandleToolCall(name: name, arguments: args, sessionKey: key)
                }
            )
            client = LocalAgentBackendFactory.makeHarnessClient(
                store: appState.localModels,
                additionalTools: ideTools,
                taskModel: { [weak appState] kind in
                    appState?.studioSetupTaskModel(for: kind)
                }
            )
        }

        let request = AgentSendRequest(
            turnID: UUID(),
            threadID: SDKAgentBackend.threadID(forSessionKey: sessionKey),
            resumeSessionID: resumeSessionID,
            prompt: userText,
            attachments: attachments,
            workingDirectory: URL(fileURLWithPath: cwdPath),
            model: requestedModel,
            effort: effectiveAgent.effort,
            permissionMode: .bypassPermissions,
            planMode: false,
            contextText: contextOverride ?? Self.buildVoiceSystemInstructions(appState: appState, targetProject: targetProject, configuration: configuration)
                + (sessionKey.hasPrefix("pet-chat-")
                    ? "\nThis is a typed conversation. Use Markdown when it helps explain your response."
                    : ""),
            mcpServers: sdkMCPs,
            permissions: SDKPermissionResolver(server: appState.permission, sessionKey: sessionKey),
            history: history
        )

        return PetCustomAgentResponder.ResolvedTurnSetup(
            client: client,
            sendRequest: request,
            sessionKey: sessionKey
        )
    }

    func checkPipelineReadiness() async -> VoiceEngineReadiness {
        guard let appState else {
            return .needsSetup("Open an RxCode workspace first.")
        }
        let effective = configuration.customAgent ?? appState.defaultTaskAgent()
        let provider = effective.provider ?? appState.selectedAgentProvider
        switch provider {
        case .claudeCode:
            return await ClaudeCodeClient().isAvailable()
                ? .ready
                : .needsSetup("Claude Code CLI is not installed. Install it or choose another custom agent in Pet Settings.")
        case .codex:
            return await CodexClient().isAvailable()
                ? .ready
                : .needsSetup("Codex CLI is not installed. Install it or choose another custom agent in Pet Settings.")
        case .acp:
            let hasEnabled = appState.acpClients.contains(where: \.enabled)
            return hasEnabled
                ? .ready
                : .needsSetup("No ACP client is enabled. Enable one in Settings → Agent or pick another custom agent.")
        case .localAgent:
            let hasChatModel = appState.localModels.installed.contains { !$0.studioKind.isStudio }
            return hasChatModel
                ? .ready
                : .needsDownload("No local chat model is installed. Download an MLX or GGUF model in Local Models first.")
        }
    }

    func resolveTargetProject(in appState: AppState) -> Project? {
        if let pinned = configuration.pinnedProjectId,
           let matched = appState.projects.first(where: { $0.id == pinned }) {
            return matched
        }
        return appState.projects.first
    }

    static func buildVoiceSystemInstructions(appState: AppState, targetProject: Project?, configuration: PetConfiguration = PetConfiguration()) -> String {
        let projectSummary: String
        if appState.projects.isEmpty {
            projectSummary = "No projects are currently registered in workspace '\(appState.activeWorkspace.name)'."
        } else {
            let list = appState.projects.map { proj in
                "- \(proj.name) (id: \(proj.id.uuidString), path: \(proj.path))"
            }.joined(separator: "\n")
            projectSummary = "Projects in workspace '\(appState.activeWorkspace.name)':\n\(list)"
        }

        let focusLine = targetProject.map {
            "Default active project: \($0.name) (id: \($0.id.uuidString), path: \($0.path))."
        } ?? "No default active project is selected."

        return """
        You are RxBuddy, RxCode's live desktop voice pet and engineering coordinator.
        Speak naturally in concise, warm, plain sentences suitable for real-time voice conversation.
        Never read out markdown syntax, code fences, UUIDs, or raw file URLs aloud — summarize clearly in 1 to 3 sentences unless the user asks for detail.

        \(configuration.conversationLanguageInstruction)

        \(focusLine)
        \(projectSummary)

        Default request context and tool priority:
        - Screen-related requests use pet tools directly. When the user says "take a look at my screen", "what is on my screen?", "read this window", or asks about currently visible content, use `ide__pet_capture` and inspect its returned image before answering. Use `ide__pet_list_capture_targets` first when needed to resolve the requested display or window. This is a direct pet action: do not dispatch a project agent, ask for a project name, or use shell commands, browser/computer-use screenshots, or external screen tools for it.
        - Unless the user explicitly names another target, interpret requests as referring to the current RxCode IDE workspace, its projects, tasks, threads, jobs, and agents. For example, "what is running?" means IDE jobs and agents; "show my tasks" means the IDE task board.
        - Never announce success, delivery, or a permission requirement before the relevant tool result establishes it. Routine user-authorized IDE operations, including sending messages to project threads, need no extra confirmation. Do not call ide__show_confirmation just to gain tool access.
        - When requesting an explicit confirmation, explain it once and wait for its popup decision. A matching permission notification is the same event, not a new request to announce.
        - IDE tools are authorized by default. Execute the user’s requested IDE actions directly without asking for tool-access permission. If an action itself needs confirmation, call `ide__show_confirmation` and wait for the popup decision; never claim that confirmation cannot be shown.
        - Use `rxcode-ide` tools FIRST to discover current state and act on IDE requests. Do not start with shell commands, computer use, web search, or external services when IDE tools cover the request.
        - Respect an explicitly named project, app, service, repository, or other target. Use `ide__get_projects` to resolve project names and IDs; for work requests, ask for the project name when none is specified or established in the conversation. Never infer the target from the default working directory or the first registered project.
        - The workspace context above is a snapshot. Refresh relevant state through IDE tools before reporting status or making changes. Read thread messages before inferring what another agent has done.

        Routing work requests:
        - When the user asks you to build, fix, change, investigate, or otherwise do project work, coordinate that work through a project agent or its task board. Do not perform the implementation yourself with shell, file-editing, or computer-use tools.
        - Resolve the named project with `ide__get_projects`. If the target is missing or ambiguous, ask which project and wait before creating a task or sending work. A default project above is only runtime context, not authorization to choose a target.
        - For requests to do work now, use `ide__send_to_thread` with the resolved project and `waitForResponse: false`, or `ide__run_task` for an existing board task. Read relevant thread/task state first to avoid duplicating work.
        - For requests to add, plan, track, or save work for later, use `ide__create_task` in the resolved project's board. Inspect existing stories/tasks first; do not launch an agent unless the user asks to start it.
        - Report what was actually dispatched or added. A tool result acknowledging a job is not evidence the work is completed.

        Capabilities via the `rxcode-ide` MCP tools:
        - Appearance: use ide__pet_look to list or switch looks, save named color/accessory variants, or import data-only sprite packs when the user asks to customize your appearance. Changes apply live without ending this conversation.
        - Visible presentation: capturing an image sends evidence to you, NOT a visible image to the user. To show/open a photo beside the pet, call `ide__pet_show_image` with its capture_id; for other local images use an absolute path. Only status=presented proves the user surface appeared. Use `ide__show_ui` for native UI. Strongly prefer a compact inline UI card directly below the speech caption, keeping the caption visible above it. The UI card fits its content and never replaces the caption: omit pet_presentation or use bubble. First reduce the answer to essential read-only information that fits at most five short visible rows, without scrolling, controls or collapse support. Use simple Text, Stat or KeyValue elements; avoid unnecessary headings, cards, tables, buttons and decorative layout. Do not choose a dedicated popover merely to show more detail. Use pet_presentation=popover only when the user explicitly requests an expanded view, essential information cannot reasonably be summarized into the caption, or the requested task requires interaction. ide__pet_show_image also accepts presentation=popover or bubble. Do not announce an image or UI opened before the result confirms visible presentation.
        - Desktop input: use `ide__pet_list_desktop_targets` then `ide__pet_focus_window`, `ide__pet_click`, `ide__pet_type_text` or `ide__pet_scroll` only for explicit user-authorized requests. Use a specific window ID when possible; x/y are fractions 0...1 from the target's top-left, independent of screenshot pixel size. Window actions raise the exact target before input and reject occlusion. Resolve ambiguity rather than guessing. Native Accessibility access is required; obey destructive-action confirmation policy. Input dispatched is not proof the application changed; inspect a fresh requested capture if needed. Never infer focus from pet travel or animation. For typing, focus/click the intended editable field first; the pet shows a typing animation while actual Unicode keyboard input is dispatched, without pressing Return.
        - Music requests are direct pet actions: use `ide__pet_music` yourself instead of dispatching a coding agent. action=connect links Apple Music through native authorization and checks account access without playing; users can also link or recheck in Pet & Voice Settings → Music. For a request to play music, call search with query, then play with a returned song_id; ask which song only if the results are ambiguous. `ide__pet_music` searches and plays real Apple Music through the pet's own player. Search first if a song is ambiguous, then play a returned song_id. Use resume, pause, status, enable or off as requested. For volume requests, call volume to read, set_volume with volume (0–100 percent) to set, or increase_volume/decrease_volume with amount (percentage points, default 5 for a little). This controls the default output device and affects ALL its audio, including the call; it is not pet-only volume. Report the returned actual volume and scope, and report unsupported devices or failed changes honestly. Off stops pet-owned playback and dismisses its player; Music.app's unrelated queue is separate. Report authorization, sign-in, subscription and service errors honestly. Do not claim playback from search or animation.
        - Status widget: use `ide__pet_status` to set, update or clear a small persistent JSON-render widget. You decide WHAT it says and HOW it is composed from native reusable primitives; there are no predefined status meanings or templates. Keep content concise and factual; replace, update or clear it when the context changes. Use {$ide: running_tasks} or {$ide: running_sessions} value bindings for live IDE counts rather than fabricating or freezing running numbers. This surface is separate from images, interactive dialogs and music.
        - Screen vision: a request to look at the screen, read or explain visible content, or answer a question about what is currently displayed authorizes a pet capture; the user does not need to say "screenshot" or "capture". Call `ide__pet_capture` for these requests. Without a target it captures the pet's current display, not necessarily the main monitor. Use `ide__pet_list_capture_targets` to resolve another monitor by name/relative position or a window by app/title; choose its ID. Ask one concise selection only if ambiguous. The pet travels and takes a photo; inspect the returned image before answering. Only an actual image block from this capture is evidence of what is currently on screen. If isError is true, image_available is false, or no image block is returned, say that capture failed and you cannot see the screen. Never invent visual details or substitute an earlier image, conversation, memory, or tool-completion status. Never capture proactively or continuously. Routine requested photos need no extra confirmation. If macOS access is denied, direct the user to System Settings → Privacy & Security → Screen & System Audio Recording; if already enabled, explain quitting and reopening the same app copy before retrying. If the selected model cannot inspect images, say so and ask the user to choose a vision-capable model.
        1. Manage works & tasks: inspect or mutate stories, tasks, task statuses, running jobs, and scheduled tasks using `ide__get_projects`, `ide__get_stories`, `ide__create_story`, `ide__get_tasks`, `ide__create_task`, `ide__update_task`, `ide__delete_task`, `ide__run_task`, `ide__get_task_status`, `ide__create_scheduled_task`, and `ide__get_running_jobs`.
        2. Manage & message threads: inspect threads with `ide__get_threads` and `ide__get_thread_messages`, or start/message coding threads across any project using `ide__send_to_thread` (pass `waitForResponse: false` when kicking off longer coding jobs so you stay responsive in voice, or `true` for quick questions).
        3. Show UI: when the user asks to show status, tasks, metrics or a dashboard, call `ide__show_ui` with a concise read-only summary in a content-sized inline card below the speech caption (`pet_presentation: "bubble"`, or omit it). Keep the speech caption visible above the UI. Prefer this inline card over a dedicated popover. Keep only essential information in at most five short visible rows, with no scrolling, interaction or collapse support. Summarize and simplify first; do not add controls or complex components that would force a popover. Reserve `pet_presentation: "popover"` for explicitly requested expanded views, indispensable detail that cannot fit, or required interaction such as a requested form.
        4. Confirmations: whenever user confirmation is needed (especially before deleting tasks, resetting work, or destructive operations), ALWAYS call `ide__show_confirmation` and wait for the user's decision.
        5. Briefings & Memory: read/publish briefings via `ide__briefing_*` and recall/store preferences via `ide__memory_*`.
        """
    }

    func playVoiceConnectedSound() {
        voiceConnectingSounds.update(isRunning: false, didFinish: false)
        // Realtime startup can return before the transport is ready. Keep its card
        // visible until the engine delivers the actual connected event.
        if actionStatusOverlayMessage == "Connecting \(PetVoiceModeKind.codexRealtime.shortTitle)…" {
            actionStatusOverlayMessage = nil
        }
        guard !isMuted, configuration.isEnabled, let session = voiceSession, !AppSupport.isTestProcess else {
            logger.debug("Skipping voice connected sound: pet disabled or no active voice session")
            return
        }
        // Hardware-audio modes (WebSocket realtime, local pipeline): play through the voice
        // engine's own cue player so the chime isn't swallowed by the capture session.
        if let driver = currentHardwareAudioDriver, driver.playConnectedCue() {
            logger.info("Played voice connected cue through voice audio engine")
            return
        }
        // WebRTC owns the audio device. Its device module (re)configures input/output right as
        // the peer connects, which drops a system sound fired at that instant — wait briefly.
        Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let session, self.voiceSession === session, self.configuration.isEnabled else { return }
            self.voiceConnectedSound?.stop()
            let sound = NSSound(named: NSSound.Name("Hero")) ?? NSSound(named: NSSound.Name("Tink"))
            sound?.volume = 0.6
            self.voiceConnectedSound = sound
            let started = sound?.play() ?? false
            self.logger.info("Played voice connected system sound (started: \(started))")
        }
    }

    func startVoiceStateSyncLoop(for session: VoiceSession) {
        stateSyncTask?.cancel()
        stateSyncTask = Task { @MainActor [weak self, weak session] in
            var lastTranscriptText = ""
            while !Task.isCancelled, let self, let session, self.voiceSession === session {
                if self.currentHardwareAudioDriver != nil {
                    session.meters.output = self.speechPlayback.envelope.level()
                }
                self.refreshPetState()

                if let lastAssistant = session.transcript.last(where: { !$0.isUser }),
                   !lastAssistant.text.isEmpty,
                   lastAssistant.text != lastTranscriptText {
                    lastTranscriptText = lastAssistant.text
                    self.showBubble(
                        PetBubbleMessage(
                            title: self.character.displayName,
                            text: lastAssistant.text,
                            isProactive: false,
                            action: nil
                        ),
                        duration: lastAssistant.isFinal ? 12.0 : 30.0
                    )
                }

                if case .failed(let err) = session.lifecycle {
                    self.voiceConnectingSounds.update(isRunning: false, didFinish: false)
                    self.actionStatusOverlayMessage = nil
                    self.alertErrorMessage = err.localizedDescription
                    break
                }
                if session.lifecycle == .stopped {
                    self.voiceConnectingSounds.update(isRunning: false, didFinish: false)
                    self.actionStatusOverlayMessage = nil
                    break
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.refreshPetState()
        }
    }

    func refreshPetState() {
        refreshToolSounds()
        if petState.isWalking {
            panelController.updatePanelLayout()
            return
        }

        if let session = voiceSession {
            switch session.lifecycle {
            case .connecting:
                petState.status = .thinking
                petState.mood = .focused
                petState.activeToolName = activeToolDescription
                panelController.updatePanelLayout()
                return
            case .active:
                petState.activeToolName = activeToolDescription
                if isStandaloneSpeaking {
                    petState.status = .speaking
                    petState.mood = .happy
                } else if activeToolDescription != nil || session.activity == .usingTools {
                    petState.status = .working
                    petState.mood = .focused
                } else {
                    switch session.activity {
                    case .listening:
                        petState.status = livePartialUserText.isEmpty ? .listening : .userSpeaking
                        petState.mood = .curious
                    case .userSpeaking:
                        petState.status = .userSpeaking
                        petState.mood = .curious
                    case .thinking:
                        petState.status = .thinking
                        petState.mood = .focused
                    case .usingTools:
                        petState.status = .working
                        petState.mood = .focused
                    case .agentSpeaking:
                        petState.status = .speaking
                        petState.mood = .happy
                    }
                }
                panelController.updatePanelLayout()
                return
            case .paused:
                petState.status = .idle
                petState.mood = .neutral
                panelController.updatePanelLayout()
                return
            case .failed:
                petState.status = .failed
                petState.mood = .concerned
                panelController.updatePanelLayout()
                return
            case .idle, .stopping, .stopped:
                break
            }
        }

        petState.activeToolName = nil
        if isStandaloneSpeaking {
            petState.status = .speaking
            petState.mood = .happy
        } else if petState.status == .celebrating || petState.status == .failed {
            // Preserve transient celebratory / error status until its timer resets it
        } else if !toolActivity.pending.isEmpty || isSendingText || (appState?.inProgressSessionCount ?? 0) > 0 {
            petState.status = .working
            petState.mood = .focused
        } else if Date().timeIntervalSince(lastInteractionAt) > 300 {
            petState.status = .sleeping
            petState.mood = .sleepy
        } else {
            petState.status = .idle
            if petState.mood == .sleepy || petState.mood == .focused {
                petState.mood = .neutral
            }
        }
        panelController.updatePanelLayout()
    }

    func speakProactivelyOrQueue(_ text: String) {
        guard !isMuted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queuedProactiveSpeech.append(text)
        startAnnouncementDeliveryIfNeeded()
    }

    /// Keep background updates in order without replacing a report already playing.
    func startAnnouncementDeliveryIfNeeded() {
        guard !isMuted, announcementTask == nil, !queuedProactiveSpeech.isEmpty else { return }
        let generation = UUID()
        announcementGeneration = generation
        announcementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.announcementGeneration == generation { self.announcementTask = nil }
            }
            while !Task.isCancelled, !self.isMuted, !self.queuedProactiveSpeech.isEmpty {
                if let session = self.voiceSession, self.isVoiceActive {
                    // Both voice modes own notification responses. A busy conversation keeps
                    // updates queued; it must never fall back to a separate agent or speaker.
                    guard session.lifecycle == .active, session.activity == .listening,
                          !self.isAwaitingVoiceTextReply(in: session),
                          !self.isLocalUserSpeaking, self.livePartialUserText.isEmpty,
                          session.meters.input < 0.04,
                          session.transcript.last.map({ !$0.isUser && $0.isFinal }) ?? true,
                          self.activeToolDescription == nil, !self.isStandaloneSpeaking,
                          self.currentHardwareAudioDriver?.hasPendingPlayback != true,
                          session.meters.output < 0.01 else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let updates = self.queuedProactiveSpeech
                    let previousEntries = Set(session.transcript.map(\.id))
                    do {
                        try await session.send(text: Self.voiceUpdatePrompt(updates, languageInstruction: self.configuration.conversationLanguageInstruction))
                        guard !Task.isCancelled, self.announcementGeneration == generation else { return }
                        self.queuedProactiveSpeech.removeFirst(updates.count)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.alertErrorMessage = "Could not deliver the update to the voice agent: \(error.localizedDescription)"
                        return
                    }
                    // Sending returns before the agent starts responding. Wait for its completed
                    // reply so a second background event cannot cancel the first pipeline turn.
                    while !Task.isCancelled, self.voiceSession === session,
                          session.lifecycle == .active,
                          !session.transcript.contains(where: {
                              !previousEntries.contains($0.id) && !$0.isUser && $0.isFinal
                          }) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                } else {
                    if self.isStandaloneSpeaking {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let text = self.queuedProactiveSpeech.removeFirst()
                    self.standaloneSpeaker.speak(text: text, synthesizer: self.localSynthesizer)
                    while !Task.isCancelled, self.isStandaloneSpeaking {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
    }

    func isAwaitingVoiceTextReply(in session: VoiceSession) -> Bool {
        guard let baseline = voiceTextReplyBaseline else { return false }
        if session.transcript.contains(where: { !$0.isUser && $0.isFinal && !baseline.contains($0.id) }) {
            voiceTextReplyBaseline = nil
            return false
        }
        return true
    }

    func showBubble(_ message: PetBubbleMessage, duration: TimeInterval) {
        bubbleDismissTask?.cancel()
        petState.bubble = message
        panelController.updatePanelLayout()
        bubbleDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            if self.petState.bubble?.id == message.id {
                self.petState.bubble = nil
                self.panelController.updatePanelLayout()
            }
        }
    }

    func scheduleTransientMoodReset(after seconds: TimeInterval) {
        transientStatusResetTask?.cancel()
        transientStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.petState.status == .celebrating || self.petState.status == .failed {
                self.petState.status = .idle
            }
            self.petState.mood = .neutral
            self.refreshPetState()
        }
    }

    func startBackgroundMonitorIfNeeded() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, self.configuration.isEnabled {
                    if let appState = self.appState {
                        self.observeIncomingPetPrompts(in: appState)
                    }
                    await self.checkScheduledDailyReportIfNeeded()
                    self.refreshPetState()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func observeIncomingPetPrompts(in appState: AppState) {
        let petConfirmations = appState.agentPrompts.confirmations.filter {
            $0.sessionKey.hasPrefix("pet-") && !$0.isMinimized
        }
        let confirmIDs = Set(petConfirmations.map(\.id))
        let newConfirms = confirmIDs.subtracting(lastObservedConfirmationIDs)
        lastObservedConfirmationIDs = confirmIDs

        // Interactive views belong to the floating pet, so they must not reopen
        // the companion window after the user closes it.
        if !configuration.isEnabled && !newConfirms.isEmpty {
            openCompanionWindow()
        }
    }

    private func checkScheduledDailyReportIfNeeded() async {
        guard configuration.dailyReportAutoEnabled, !isGeneratingDailyReport else { return }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let hour = comps.hour, let minute = comps.minute else {
            return
        }
        let todayKey = String(format: "%04d-%02d-%02d", y, m, d)
        guard configuration.lastAutoDailyReportDayKey != todayKey else { return }

        let nowMinutes = hour * 60 + minute
        let scheduledMinutes = configuration.dailyReportHour * 60 + configuration.dailyReportMinute
        if nowMinutes >= scheduledMinutes && nowMinutes <= scheduledMinutes + 30 {
            configuration.lastAutoDailyReportDayKey = todayKey
            await triggerDailyReport(speakAloud: isVoiceActive || configuration.proactiveMode == .voiceAndBubble, openSheet: false)
        }
    }
}
