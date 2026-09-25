import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Actions of `TaskFormSheet`: loading the draft, tag editing, suggestion-agent
/// helpers, attachment import and saving.
extension TaskFormSheet {

    func loadDraft() {
        switch payload {
        case .task(let incoming):
            isStory = false
            task = incoming
            isExistingRecord = appState.task(id: incoming.id) != nil
            if appState.projects.allSatisfy({ $0.id != task.projectId }) {
                task.projectId = defaultProjectId
            }
            // A new task starts on the last model picked, so it's ready to run.
            if !isExistingRecord, !task.agent.isAssigned {
                let fallback = appState.defaultTaskAgent()
                task.agent.provider = fallback.provider
                task.agent.model = fallback.model
            }
        case .story(let incoming):
            isStory = true
            story = incoming
            isExistingRecord = appState.stories().contains { $0.id == incoming.id }
            if appState.projects.allSatisfy({ $0.id != story.projectId }) {
                story.projectId = defaultProjectId
            }
        }
        creationMode = .resolved(
            isExistingRecord: isExistingRecord,
            isStory: isStory,
            requested: initialMode
        )
    }

    /// Opens a blank task form assigned to this story. A story that hasn't
    /// been saved yet is saved first — the task needs an existing parent, and
    /// the story form stays open for further edits.
    func newStoryTask() {
        if !isExistingRecord {
            story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertStory(story)
            isExistingRecord = true
        }
        childTask = .task(appState.newTaskDraft(inStory: story))
    }

    func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
        tagInput = ""
        guard !trimmed.isEmpty else { return }
        // Reuse the board's spelling of a label that differs only by case.
        appendTag(board.allTags.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed)
    }

    func appendTag(_ tag: String) {
        tagInput = ""
        if isStory {
            if !story.tags.contains(tag) { story.tags.append(tag) }
        } else {
            if !task.tags.contains(tag) { task.tags.append(tag) }
        }
    }

    func removeTag(_ tag: String) {
        if isStory {
            story.tags.removeAll { $0 == tag }
        } else {
            task.tags.removeAll { $0 == tag }
        }
    }

    /// Summarizes the draft's description into a title. Unlike auto-fill this
    /// does overwrite — it is only reachable by pressing the button, and the
    /// point of pressing it is to replace whatever the title says now.
    func generateTitle() {
        guard !isGeneratingTitle, !isAutoFilling else { return }
        let details = currentDetails
        let wasStory = isStory
        let itemId = wasStory ? story.id : task.id
        let projectId = currentProjectId
        let parentTitle = wasStory ? nil : board.story(id: task.storyId)?.title
        isGeneratingTitle = true
        Task {
            defer { isGeneratingTitle = false }
            guard let title = await appState.suggestTitle(details: details, storyTitle: parentTitle, projectId: projectId) else { return }
            guard isStory == wasStory, (wasStory ? story.id : task.id) == itemId,
                  currentProjectId == projectId else { return }
            if wasStory {
                story.title = title
            } else {
                task.title = title
            }
        }
    }

    /// Fills the draft's empty properties from the selected suggestion model. The
    /// draft is only filled, never overwritten, and nothing is saved until
    /// the user presses Save.
    func autoFill() {
        guard !isAutoFilling, !isGeneratingTitle else { return }
        // Unconfirmed combo-box text is still a user choice and must win.
        if let version = TaskSingleValueCombo.resolve(versionInput, in: board.allVersions) {
            field(\.version, \.version).wrappedValue = version
        }
        if let milestone = TaskSingleValueCombo.resolve(milestoneInput, in: board.allMilestones) {
            field(\.milestone, \.milestone).wrappedValue = milestone
        }
        isAutoFilling = true
        let wasStory = isStory
        let storyDraft = story
        let taskDraft = task
        Task {
            defer { isAutoFilling = false }
            let suggestion: TaskClassification?
            if wasStory {
                suggestion = await appState.suggestClassification(for: storyDraft)
            } else {
                suggestion = await appState.suggestClassification(for: taskDraft)
            }
            guard let suggestion, isStory == wasStory else { return }
            if wasStory, story.id == storyDraft.id, story.projectId == storyDraft.projectId {
                suggestion.apply(to: &story, board: board)
            } else if !wasStory, task.id == taskDraft.id, task.projectId == taskDraft.projectId {
                suggestion.apply(to: &task, board: board)
            }
        }
    }

    func selectSuggestionAgent(_ agent: TaskAgentConfig?) {
        appState.setConfiguredTaskSuggestionAgent(agent)
        suggestionAgent = agent
    }

    func handleAttachmentImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard let attachment = AttachmentFactory.fromFileURL(url) else { continue }
            let dto = attachment.persistableInTaskBoard().dto
            guard !task.attachments.contains(where: { $0.path == dto.path }) else { continue }
            task.attachments.append(dto)
        }
    }

    func save() {
        guard canSave else { return }
        // Values typed but not yet confirmed with Return still count.
        if let version = TaskSingleValueCombo.resolve(versionInput, in: board.allVersions) {
            field(\.version, \.version).wrappedValue = version
        }
        if let milestone = TaskSingleValueCombo.resolve(milestoneInput, in: board.allMilestones) {
            field(\.milestone, \.milestone).wrappedValue = milestone
        }
        if !tagInput.trimmingCharacters(in: .whitespaces).isEmpty {
            addTag()
        }
        if isStory {
            if !storyTaskDrafts.isEmpty {
                saveComposedStory()
                return
            }
            story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertStory(story)
        } else {
            task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertTask(task)
        }
        dismiss()
    }
}
