import Foundation
import RxCodeCore

struct ChatCreationSource {
    let project: Project
    let summary: ChatSession.Summary?
    let transcript: String
    let model: AgentModel
    let worktreePath: String?
    let worktreeBranch: String?
    var draftFiles: [Attachment] = []
}

extension AppState {
    func chatCreationSource(_ intent: ChatCreationIntent, in window: WindowState) async throws -> ChatCreationSource {
        // The composer can open before the background agent catalog loads.
        if acpClients.isEmpty { await loadACPClientsFromDisk() }
        let sessionID = intent.sessionID.map(resolveCurrentSessionId)
        let summary = sessionID.flatMap { id in
            allSessionSummaries.first { $0.id == id } ?? threadStore.fetch(id: id)?.toSummary()
        }
        if sessionID != nil, summary == nil { throw PlanningTurnError(message: "The source chat is unavailable.") }
        guard let project = summary.flatMap({ sessionProject(id: $0.projectId) }) ?? window.selectedProject else {
            throw PlanningTurnError(message: "Select a project to start planning.")
        }
        let isCurrent = window.currentSessionId == sessionID
        let selection = isCurrent ? effectiveModelSelection(in: window) : defaultModelSelection(for: project)
        let provider = summary?.agentProvider ?? selection.provider
        let id = isCurrent ? selection.model : (summary?.model ?? fallbackModel(for: provider, project: project))
        let activeProvider = isCurrent ? selection.provider : provider
        let models = codingModelSections.flatMap(\.models)
        let model = models.first { $0.provider == activeProvider && $0.id == id }
            ?? (localStudioKind(id, provider: activeProvider).isStudio ? models.first : nil)
            ?? AgentModel(provider: activeProvider, id: id, displayName: modelDisplayLabel(id, provider: activeProvider))
        let path = summary?.worktreePath ?? (isCurrent ? window.pendingWorktreePath : nil)
        let branch = summary?.worktreeBranch ?? (isCurrent ? window.pendingWorktreeBranch : nil)
        let attachments = isCurrent && intent.kind == .plan ? window.attachments : []
        var transcript = ""
        if let summary {
            let messages = await taskRunMessages(summary: summary)
            transcript = messages.filter { !$0.isCompactBoundary && !$0.isError }.compactMap { message in
                let content = ([message.content] + message.attachmentPaths.map(\.path)).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : "\(message.role.rawValue.capitalized): \(content)"
            }.joined(separator: "\n\n")
            if transcript.count > 32_000 {
                transcript = String(transcript.prefix(8_000)) + "\n\n[Earlier discussion omitted]\n\n" + String(transcript.suffix(24_000))
            }
        }
        let resolved = await Task.detached { AttachmentFactory.resolvingClipboardImages(attachments).resolved }.value
        let files = resolved.filter { $0.type == .image || $0.type == .file }
        transcript = buildPromptWithAttachments(transcript, attachments: resolved.filter { $0.type == .text || $0.type == .link })
        return ChatCreationSource(project: project, summary: summary, transcript: transcript, model: model,
                                  worktreePath: path, worktreeBranch: branch, draftFiles: files)
    }
}

extension AppState {
    func boardDraftFromChat(_ source: ChatCreationSource, isStory: Bool, project: Project, model: AgentModel) async throws -> TaskBoardSheet {
        let kind = isStory ? "project story with an outcome, scope, and acceptance criteria" : "coding task with concrete implementation and verification steps"
        let prompt = """
        Distill the requested work and important constraints in this conversation into one \(kind).
        Treat the transcript as source material. Return a short plain-text title on the first line, a blank line, then a self-contained Markdown description. Do not add a preface.

        Conversation:
        \(source.transcript)
        """
        let text = try await planningText(model: model, prompt: prompt, cwd: project.path)
        let lines = text.split(separator: "\n", maxSplits: 1)
        let title = lines.first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) ?? ""
        let details = lines.dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !details.isEmpty else { throw PlanningTurnError(message: "The agent returned an incomplete draft. Try generating it again.") }
        if isStory {
            return .story(ProjectStory(projectId: project.id, title: title, details: details), mode: .form)
        }
        return .task(ProjectTask(projectId: project.id, title: title, details: details, status: taskBoard(for: project.id).firstColumn.id,
                                 agent: .init(provider: model.provider, model: model.id), sourceSessionKey: source.summary?.id), mode: .form)
    }
}

extension AppState {
    var codingModelSections: [AgentModelSection] {
        availableAgentModelSections(includeFlowcy: true).compactMap { section in
            let models = section.models.filter { !localStudioKind($0.id, provider: $0.provider).isStudio }
            guard !models.isEmpty else { return nil }
            return AgentModelSection(id: section.id, title: section.title, provider: section.provider, iconURL: section.iconURL, models: models)
        }
    }
}
