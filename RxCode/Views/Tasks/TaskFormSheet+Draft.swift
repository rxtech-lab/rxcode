import PDFKit
import RxCodeCore
import SwiftUI

/// The AI flow of `TaskFormSheet`: describe a task or story once and review
/// what the suggestion agent drafts from it.
extension TaskFormSheet {
    // MARK: - AI flow

    var draftComposer: some View {
        Form {
            switch draftStep {
            case .describe: describeSections
            case .review: reviewSections
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingStoryTaskDraft) { draft in
            StoryTaskDraftSheet(
                draft: draft,
                isNew: !storyTaskDrafts.contains { $0.id == draft.id }
            ) { saved in
                if let index = storyTaskDrafts.firstIndex(where: { $0.id == saved.id }) {
                    storyTaskDrafts[index] = saved
                } else {
                    storyTaskDrafts.append(saved)
                }
            }
        }
    }

    /// Step one: what to draft from.
    @ViewBuilder
    var describeSections: some View {
            Section(isStory ? "Create Story with Tasks" : "Create Task") {
                Picker("Project", selection: projectBinding) {
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
            }

            Section {
                // The same editor the form uses, so the source description
                // takes pasted and dropped images here too. A task keeps them
                // in its attachment list; a story has none, so they stay
                // Markdown links in the text the draft is generated from.
                MarkdownDescriptionEditor(
                    text: $draftPrompt,
                    attachments: isStory ? nil : $task.attachments,
                    placeholder: isStory
                        ? String(localized: "Describe the story and the tasks it needs")
                        : String(localized: "Describe what needs doing"),
                    height: 130,
                    identifierPrefix: "story-create-prompt"
                )
                // An edited source makes the draft below stale, so it goes.
                .onChange(of: draftPrompt) { _, _ in clearGeneratedDraft() }

                Button {
                    showingSourceFilePicker = true
                } label: {
                    Label("Choose File…", systemImage: "doc")
                }
                .disabled(isGeneratingDraft)
            } header: {
                Text("Description")
            } footer: {
                if let draftError {
                    Text(draftError)
                        .foregroundStyle(.red)
                } else {
                    Text(isStory
                        ? "Describe the story and tasks, or choose a text or PDF file."
                        : "Describe the task, or choose a text or PDF file.")
                }
            }
    }

    /// Step two: the model's draft, editable before it is created.
    @ViewBuilder
    var reviewSections: some View {
        if isStory {
            storyDraftSections
        } else {
            taskDraftSection
        }
    }

    @ViewBuilder
    var storyDraftSections: some View {
        Section {
            TextField("Title", text: $story.title, prompt: Text("Story title"))
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier("story-create-title")
        } header: {
            Text("Story")
        } footer: {
            if let draftError {
                Text(draftError).foregroundStyle(.red)
            }
        }

        Section {
            ForEach(storyTaskDrafts) { draft in
                storyTaskDraftRow(draft)
            }
            Button {
                editingStoryTaskDraft = StoryTaskDraft(title: "", details: "")
            } label: {
                Label("Add Task…", systemImage: "plus")
            }
            .accessibilityIdentifier("story-create-add-task")
        } header: {
            Text("Tasks")
        } footer: {
            Text("Click a task to edit it before the story is created.")
        }
    }

    func storyTaskDraftRow(_ draft: StoryTaskDraft) -> some View {
        HStack(spacing: 8) {
            Button {
                editingStoryTaskDraft = draft
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title.isEmpty ? String(localized: "Untitled task") : draft.title)
                        .foregroundStyle(draft.title.isEmpty ? ClaudeTheme.textTertiary : ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    if !draft.details.isEmpty {
                        Text(draft.details)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                storyTaskDrafts.removeAll { $0.id == draft.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove task")
        }
    }

    /// The generated task, editable before it is saved. Only the fields worth
    /// correcting in place are here; the rest can be changed once it exists.
    var taskDraftSection: some View {
        Section {
            TextField("Title", text: $task.title, prompt: Text("Task title"))
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier("task-create-title")
            TextField("Details", text: $task.details, prompt: Text("Task details"), axis: .vertical)
                .multilineTextAlignment(.leading)
                .lineLimit(3...12)
            draftPropertyChips
        } header: {
            Text("Draft")
        } footer: {
            if let draftError {
                Text(draftError).foregroundStyle(.red)
            }
        }
    }

    /// What the model filled in, as read-only chips.
    @ViewBuilder
    var draftPropertyChips: some View {
        let chips = suggestedProperties
        if !chips.isEmpty {
            LabeledContent("Suggested properties") {
                FlowLayout(spacing: 4) {
                    ForEach(chips, id: \.text) { chip in
                        TaskBoardChipLabel(icon: chip.icon, title: chip.text, isActive: true)
                    }
                }
            }
        }
    }

    var suggestedProperties: [(icon: String, text: String)] {
        var chips: [(icon: String, text: String)] = []
        if let type = board.itemType(id: task.typeId) {
            chips.append((icon: "circle.fill", text: type.name))
        }
        if let priority = task.priority {
            chips.append((icon: priority.systemImage, text: String(localized: priority.displayName)))
        }
        if let parent = board.story(id: task.storyId) {
            chips.append((icon: "square.stack.3d.up", text: parent.title))
        }
        if let version = task.version, !version.isEmpty {
            chips.append((icon: "tag", text: version))
        }
        if let milestone = task.milestone, !milestone.isEmpty {
            chips.append((icon: "flag", text: milestone))
        }
        chips += task.tags.map { (icon: "number", text: $0) }
        return chips
    }

    var draftComposerFooter: some View {
        HStack {
            if draftStep == .review {
                Button {
                    draftError = nil
                    draftStep = .describe
                } label: {
                    Label("Revise", systemImage: "chevron.left")
                }
                .help("Go back and change the description")
                .accessibilityIdentifier("draft-revise")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            switch draftStep {
            case .describe:
                Button {
                    Task { await generateDraft() }
                } label: {
                    HStack(spacing: 6) {
                        if isGeneratingDraft {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Generate Draft")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerateDraft)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("story-create-generate")
            case .review:
                Button(isStory ? "Create Story and Tasks" : "Create Task") {
                    if isStory { saveComposedStory() } else { save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateFromDraft)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(isStory ? "story-create-save" : "task-create-save")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - AI flow actions

    func generateDraft() async {
        guard canGenerateDraft else { return }
        if isStory {
            await generateStoryDraft()
        } else {
            await generateTaskDraft()
        }
        // A stale result is discarded, so only move on when one landed.
        if hasGeneratedDraft { draftStep = .review }
    }

    func generateStoryDraft() async {
        let source = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let projectId = story.projectId
        isGeneratingDraft = true
        draftError = nil
        defer { isGeneratingDraft = false }
        let draft = await appState.suggestStoryDraft(source: String(source.prefix(30_000)), projectId: projectId)
        guard isStory, draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == source,
              story.projectId == projectId else { return }
        guard let draft else {
            let title = TaskTitleSuggestion.fallback(from: source)
            story.title = title
            story.details = source
            storyTaskDrafts = [StoryTaskDraft(title: title, details: source)]
            draftError = String(localized: "The suggestion agent did not respond. Review this single-task draft before creating it.")
            return
        }
        story.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        story.details = source
        storyTaskDrafts = draft.tasks.prefix(12).map {
            StoryTaskDraft(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                           details: $0.details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Turns the description into a reviewable task: the source stays the
    /// description — it is what the agent is eventually asked to do — and the
    /// model writes the title and fills the empty properties, the same two
    /// calls quick add makes in the background.
    func generateTaskDraft() async {
        let source = String(draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30_000))
        guard !source.isEmpty else { return }
        let projectId = task.projectId
        isGeneratingDraft = true
        draftError = nil
        defer { isGeneratingDraft = false }

        var candidate = task
        candidate.details = source
        candidate.title = ""
        // Independent prompts: run them together rather than paying for two
        // round trips in a row.
        async let suggestedTitle = appState.suggestTitle(details: source, storyTitle: nil, projectId: projectId)
        async let classification = appState.suggestClassification(for: candidate)
        let (title, suggestion) = await (suggestedTitle, classification)

        guard !isStory, draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30_000) == source,
              task.projectId == projectId else { return }
        task.details = source
        task.title = title ?? TaskTitleSuggestion.fallback(from: source)
        suggestion?.apply(to: &task, board: board)
        hasTaskDraft = true
        if title == nil, suggestion == nil {
            draftError = String(localized: "The suggestion agent did not respond. Review this draft before creating it.")
        }
    }

    /// Drops what the model produced, keeping the source text: the outline
    /// belongs to the description it was generated from.
    func clearGeneratedDraft() {
        storyTaskDrafts = []
        hasTaskDraft = false
        draftError = nil
    }

    func importSourceFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { draftError = error.localizedDescription }
            return
        }
        Task {
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    try DraftSourceFile.read(url)
                }.value
                let heading = "# \(url.lastPathComponent)\n\n"
                draftPrompt += (draftPrompt.isEmpty ? "" : "\n\n") + heading + content
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    func saveComposedStory() {
        guard !storyTaskDrafts.isEmpty else { return }
        story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !story.title.isEmpty,
              storyTaskDrafts.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return }
        appState.upsertStory(story)
        for draft in storyTaskDrafts {
            var task = appState.newTaskDraft(inStory: story)
            task.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            task.details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
            task.agent = appState.defaultTaskAgent()
            appState.upsertTask(task)
        }
        dismiss()
    }
}

/// Adds or edits one task of a generated story outline. Works on a copy, so
/// Cancel leaves the outline as it was.
private struct StoryTaskDraftSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: TaskFormSheet.StoryTaskDraft
    let isNew: Bool
    let onSave: (TaskFormSheet.StoryTaskDraft) -> Void

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "New Task" : "Edit Task") {
                    TextField("Title", text: $draft.title, prompt: Text("What needs doing?"))
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("story-draft-task-title")
                    TextField("Details", text: $draft.details, prompt: Text("Task details"), axis: .vertical)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("story-draft-task-details")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("story-draft-task-save")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 360)
    }
}

private enum DraftSourceFile {
    nonisolated static func read(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else {
            throw DraftSourceFileError.tooLarge
        }
        let content: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw DraftSourceFileError.unreadable }
            content = document.string ?? ""
        } else {
            content = try String(contentsOf: url, encoding: .utf8)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftSourceFileError.empty }
        return String(trimmed.prefix(30_000))
    }
}

private enum DraftSourceFileError: LocalizedError {
    case tooLarge, unreadable, empty

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "The selected file is too large (20 MB maximum).")
        case .unreadable: String(localized: "Could not read the selected file.")
        case .empty: String(localized: "The selected file contains no readable text.")
        }
    }
}
