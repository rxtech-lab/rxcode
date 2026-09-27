import Foundation
import os
import RxCodeCore

/// AI suggestions for the task board: titles, classifications, story and
/// scheduled task drafts, and cron expressions, all run on the general AI model.
extension AppState {
    /// Asks the selected suggestion agent for a title and for the task's properties, and
    /// fills in the ones still empty. The task is re-read after the (slow)
    /// calls, so edits made meanwhile are kept and a deleted task is left
    /// alone; the title is only replaced while it is still the placeholder
    /// quick add derived, never once the user has typed their own.
    func enrichTask(id: UUID, provisionalTitle: String?) async {
        defer { classifyingTaskIds.remove(id) }
        guard let task = task(id: id) else { return }
        // Independent prompts: run them together rather than paying for two
        // round trips in a row while the card sits under a spinner.
        async let title = suggestTitle(details: task.details, storyTitle: storyTitle(for: task), projectId: task.projectId)
        async let classification = suggestClassification(for: task)
        let (suggestedTitle, suggestion) = await (title, classification)

        guard var current = self.task(id: id) else { return }
        let before = current
        if let suggestedTitle, current.title.isEmpty || current.title == provisionalTitle {
            current.title = suggestedTitle
        }
        suggestion?.apply(to: &current, board: taskBoard(for: current.projectId))
        if current != before {
            upsertTask(current)
        }
    }

    /// The selected model's suggested properties for `task`, which may be an
    /// unsaved draft. `nil` when no agent could answer.
    func suggestClassification(for task: ProjectTask) async -> TaskClassification? {
        let board = taskBoard(for: task.projectId)
        let prompt = TaskClassification.prompt(
            title: task.title,
            details: task.details,
            storyTitle: board.story(id: task.storyId)?.title,
            board: board,
            startsAfterCandidates: TaskClassification.startsAfterCandidates(for: task, board: board).map(\.title)
        )
        return await parseTaskClassification(prompt: prompt, projectId: task.projectId)
    }

    func suggestClassification(for story: ProjectStory) async -> TaskClassification? {
        let prompt = TaskClassification.prompt(
            title: story.title,
            details: story.details,
            storyTitle: nil,
            board: taskBoard(for: story.projectId),
            isStory: true
        )
        return await parseTaskClassification(prompt: prompt, projectId: story.projectId)
    }

    private func parseTaskClassification(prompt: String, projectId: UUID) async -> TaskClassification? {
        guard let raw = await runTaskAgentCompletion(prompt: prompt, projectId: projectId) else {
            logger.warning("[Tasks] no classification response")
            return nil
        }
        guard let suggestion = TaskClassification.parse(raw) else {
            logger.warning("[Tasks] unparseable classification response")
            return nil
        }
        return suggestion
    }

    /// A one-line title summarizing `details`, from the selected suggestion agent.
    /// Takes the text rather than a record so an unsaved draft — and a story
    /// as much as a task — can ask for one. `nil` when the description is
    /// empty or no agent could answer.
    func suggestTitle(details: String, storyTitle: String?, projectId: UUID) async -> String? {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = TaskTitleSuggestion.prompt(details: trimmed, storyTitle: storyTitle)
        guard let raw = await runTaskAgentCompletion(prompt: prompt, projectId: projectId) else {
            logger.warning("[Tasks] no title response")
            return nil
        }
        return TaskTitleSuggestion.parse(raw)
    }

    /// Produces an unsaved story and task outline for the creation preview.
    func suggestStoryDraft(source: String, projectId: UUID) async -> StoryDraftSuggestion? {
        guard let raw = await runTaskAgentCompletion(
            prompt: StoryDraftSuggestion.prompt(source: source),
            projectId: projectId
        ) else { return nil }
        return StoryDraftSuggestion.parse(raw)
    }

    /// Produces an unsaved scheduled task — name, prompt, cron — from a
    /// free-form description, for the scheduled task creation preview.
    func suggestScheduledTaskDraft(source: String, projectId: UUID?) async -> ScheduledTaskDraftSuggestion? {
        guard let raw = await runTaskAgentCompletion(
            prompt: ScheduledTaskDraftSuggestion.prompt(source: source),
            projectId: projectId
        ) else { return nil }
        return ScheduledTaskDraftSuggestion.parse(raw)
    }

    /// A cron expression for a schedule described in natural language. A
    /// one-off model overrides Settings without changing the saved selection.
    func suggestCronExpression(description: String, projectId: UUID?, model: GeneralAIModel? = nil) async -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = await runTaskAgentCompletion(
                  prompt: CronExpressionSuggestion.prompt(description: String(trimmed.prefix(2_000))),
                  projectId: projectId,
                  model: model,
                  verbatim: true
              )
        else { return nil }
        return CronExpressionSuggestion.parse(raw)
    }

    /// The title of the story a task belongs to, if any.
    private func storyTitle(for task: ProjectTask) -> String? {
        taskBoard(for: task.projectId).story(id: task.storyId)?.title
    }

    /// Runs a one-shot task prompt on the selected or supplied general AI model.
    /// `verbatim` skips Claude's summary cleanup for replies that carry code.
    func runTaskAgentCompletion(prompt: String, projectId: UUID?, model: GeneralAIModel? = nil, verbatim: Bool = false) async -> String? {
        let agent: TaskAgentConfig
        switch model ?? generalAIModel() {
        case .appleIntelligence:
            if FoundationModelSummarizationService.isAvailable {
                return await foundationModelSummarization.generatePlainCompletion(
                    instructions: "You are a precise assistant inside a developer tool. Follow the requested output format exactly.",
                    prompt: prompt
                )
            }
            logger.warning("[Tasks] Apple Intelligence is unavailable; using the default task agent")
            agent = defaultTaskAgent()
        case .taskAgent:
            agent = defaultTaskAgent()
        case .agent(let configured):
            agent = configured
        }
        switch agent.provider ?? selectedAgentProvider {
        case .claudeCode:
            if verbatim {
                return await claude.generateRawResponse(prompt: prompt, model: agent.model ?? "haiku")
            }
            return await claude.generatePlainSummary(prompt: prompt, model: agent.model ?? "haiku", limit: 2000)
        case .codex:
            return await codex.generateCodexPlainSummary(prompt: prompt, model: agent.model)
        case .acp:
            guard let parts = acpSelectionParts(for: agent.model),
                  let spec = acpClients.first(where: { $0.id == parts.clientId && $0.enabled })
            else {
                logger.warning("[Tasks] selected ACP suggestion client is unavailable")
                return nil
            }
            let cwd = projects.first(where: { $0.id == projectId })?.path
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            return await acp.generatePlainResponse(
                prompt: prompt,
                model: parts.model.isEmpty ? nil : parts.model,
                spec: spec,
                cwd: cwd
            )
        }
    }
}
