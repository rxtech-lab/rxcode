import RxCodeCore
import SwiftUI

/// Creates or edits a scheduled task: project, name, model, prompt, and cron
/// schedule, with a live preview of the next runs. Created with AI, it first
/// asks for a description and opens the form on the suggestion agent's draft.
struct ScheduledTaskFormSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    /// Set when confirming an agent's `ide__create_scheduled_task` proposal:
    /// receives the task to add, or `nil` on cancel, instead of the sheet
    /// saving directly.
    let onConfirm: ((ScheduledTask?) -> Void)?
    @State private var draft: ScheduledTask
    /// Whether the AI describe step is showing instead of the form.
    @State private var isDescribing: Bool
    @State private var draftPrompt = ""
    @State private var isGeneratingDraft = false
    @State private var draftError: String?
    /// The form holds a draft generated from `draftPrompt`, so the describe
    /// step can return to it without regenerating.
    @State private var hasGeneratedDraft = false
    @State private var suggestionAgent: GeneralAIModel = .taskAgent
    @State private var isGeneratingCron = false
    @State private var cronError: String?

    init(
        task: ScheduledTask,
        isNew: Bool,
        mode: TaskCreationMode? = nil,
        onConfirm: ((ScheduledTask?) -> Void)? = nil
    ) {
        self.isNew = isNew
        self.onConfirm = onConfirm
        _draft = State(initialValue: task)
        _isDescribing = State(initialValue: isNew && onConfirm == nil && mode == .ai)
    }

    private var isProposal: Bool { onConfirm != nil }

    private var title: LocalizedStringKey {
        if isProposal { return "Add Scheduled Task?" }
        return isNew ? "New Scheduled Task" : "Edit Scheduled Task"
    }

    private var saveTitle: LocalizedStringKey {
        if isProposal { return "Add" }
        return isNew ? "Create" : "Save"
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPrompt: String {
        draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parseResult: Result<CronExpression, CronExpression.ParseError> {
        Result { () throws(CronExpression.ParseError) in try CronExpression(draft.cronExpression) }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedPrompt.isEmpty
            && appState.projects.contains { $0.id == draft.projectId }
            && (try? parseResult.get()) != nil
    }

    /// The schedule field holds a description rather than an expression.
    private var cronIsNaturalLanguage: Bool {
        CronExpressionSuggestion.isNaturalLanguage(draft.cronExpression)
    }

    private var canGenerateDraft: Bool {
        !isGeneratingDraft
            && !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && appState.projects.contains { $0.id == draft.projectId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isDescribing {
                    describeForm
                } else {
                    editForm
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDescribing {
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
                        .disabled(!canGenerateDraft)
                        .accessibilityIdentifier("scheduled-task-generate")
                    } else {
                        Button(saveTitle) { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .frame(width: 520, height: 580)
        .onAppear { suggestionAgent = appState.generalAIModel() }
        .interactiveDismissDisabled(isProposal)
        // Settles the proposal however the sheet closes; a no-op after Add.
        .onDisappear { onConfirm?(nil) }
    }

    /// The AI flow's first step: what the task should do and when.
    private var describeForm: some View {
        Form {
            Section {
                Picker("Project", selection: $draft.projectId) {
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
            }

            Section {
                TextEditor(text: $draftPrompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .disabled(isGeneratingDraft)
                    .accessibilityIdentifier("scheduled-task-describe")
                HStack {
                    if hasGeneratedDraft {
                        Button {
                            isDescribing = false
                        } label: {
                            Label("Back to Draft", systemImage: "chevron.right")
                        }
                        .disabled(isGeneratingDraft)
                        .help("Return to the current draft without regenerating it")
                        .accessibilityIdentifier("scheduled-task-back-to-draft")
                    }

                    Spacer()

                    Text("AI model")
                    SuggestionAgentMenu(agent: $suggestionAgent)
                        .disabled(isGeneratingDraft)
                        .accessibilityIdentifier("scheduled-task-suggestion-model")
                }
            } header: {
                Text("Description")
            } footer: {
                if let draftError {
                    Text(draftError)
                        .foregroundStyle(.red)
                } else {
                    Text("Describe what should run and when, like \"every weekday at 9:00, check for outdated dependencies\".")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var editForm: some View {
        Form {
            if isProposal {
                Section {
                    Label("An agent proposed this scheduled task from chat. Review it, then add it or cancel.", systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if hasGeneratedDraft {
                Section {
                    if let draftError {
                        Label(draftError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(ClaudeTheme.statusWarning)
                    }
                    HStack {
                        Label("Drafted by AI from your description.", systemImage: "sparkles")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            draftError = nil
                            isDescribing = true
                        } label: {
                            Label("Revise", systemImage: "chevron.left")
                        }
                        .help("Go back to the description and generate a new draft")
                        .accessibilityIdentifier("scheduled-task-revise")
                    }
                }
            }
            Section {
                Picker("Project", selection: $draft.projectId) {
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                TextField("Name", text: $draft.name, prompt: Text("Daily dependency check"))
                LabeledContent("Model") {
                    modelMenu
                }
                Toggle("Enabled", isOn: $draft.isEnabled)
            }

            Section("Prompt") {
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
            }

            Section {
                HStack {
                    TextField("Cron expression", text: $draft.cronExpression, prompt: Text("0 9 * * 1-5"))
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .disabled(isGeneratingCron)
                        .onChange(of: draft.cronExpression) { _, _ in cronError = nil }
                    if cronIsNaturalLanguage || isGeneratingCron {
                        Button {
                            Task { await generateCronExpression() }
                        } label: {
                            HStack(spacing: 4) {
                                if isGeneratingCron {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text("Generate")
                            }
                        }
                        .disabled(isGeneratingCron)
                        .help("Turn this description into a cron expression")
                        .accessibilityIdentifier("scheduled-task-generate-cron")
                    }
                    presetMenu
                }
                schedulePreview
            } header: {
                Text("Schedule")
            } footer: {
                Text("Five fields: minute, hour, day of month, month, day of week. Times use your local time zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Asks the suggestion agent for a name, prompt, and schedule, then shows
    /// them in the form for review. Without an answer the description becomes
    /// the prompt, so nothing typed is lost.
    private func generateDraft() async {
        let source = String(draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30_000))
        guard canGenerateDraft else { return }
        isGeneratingDraft = true
        draftError = nil
        defer { isGeneratingDraft = false }
        if let suggestion = await appState.suggestScheduledTaskDraft(source: source, projectId: draft.projectId) {
            draft.name = suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.prompt = suggestion.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.cronExpression = suggestion.cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            draft.name = TaskTitleSuggestion.fallback(from: source)
            draft.prompt = source
            draftError = String(localized: "The suggestion agent did not respond. Review the schedule before creating it.")
        }
        hasGeneratedDraft = true
        isDescribing = false
    }

    /// Replaces a natural-language schedule with the suggestion agent's cron
    /// expression. The field keeps the description when no answer parses, or
    /// when it was edited while the agent was working.
    private func generateCronExpression() async {
        let description = draft.cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGeneratingCron, !description.isEmpty else { return }
        isGeneratingCron = true
        cronError = nil
        let expression = await appState.suggestCronExpression(description: description, projectId: draft.projectId)
        isGeneratingCron = false
        guard draft.cronExpression.trimmingCharacters(in: .whitespacesAndNewlines) == description else { return }
        if let expression {
            draft.cronExpression = expression
        } else {
            cronError = String(localized: "Could not generate a cron expression. Try rewording the schedule or pick a preset.")
        }
    }

    /// Picks the model each run uses. "Default task agent" stores no model, so
    /// runs follow whatever Settings → Tasks resolves to at run time.
    private var modelMenu: some View {
        Menu {
            Button("Default task agent") {
                draft.agent.provider = nil
                draft.agent.model = nil
            }
            Divider()
            ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { model in
                        Button(model.displayName) {
                            draft.agent.provider = model.provider
                            draft.agent.model = model.id
                        }
                    }
                }
            }
        } label: {
            TaskBoardChipLabel(
                icon: "sparkles",
                title: modelMenuTitle,
                isActive: draft.agent.isAssigned
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The model each run of this task uses")
    }

    private var modelMenuTitle: String {
        guard draft.agent.isAssigned else {
            return String(localized: "Default (\(appState.taskAgentLabel(appState.defaultTaskAgent())))")
        }
        return appState.taskAgentLabel(draft.agent)
    }

    private var presetMenu: some View {
        Menu {
            ForEach(CronPreset.all) { preset in
                Button {
                    draft.cronExpression = preset.expression
                } label: {
                    Text("\(Text(preset.title)) (\(preset.expression))")
                }
            }
        } label: {
            Label("Presets", systemImage: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick a common schedule")
    }

    @ViewBuilder
    private var schedulePreview: some View {
        if let cronError {
            Label(cronError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.statusError)
        } else if cronIsNaturalLanguage || isGeneratingCron {
            Label("Click Generate to turn this description into a cron expression.", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            parsedSchedulePreview
        }
    }

    @ViewBuilder
    private var parsedSchedulePreview: some View {
        switch parseResult {
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.statusError)
        case .success(let cron):
            let upcoming = Self.upcomingRuns(of: cron, count: 3)
            if upcoming.isEmpty {
                Label("This schedule never runs.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.statusWarning)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next runs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(upcoming, id: \.self) { date in
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func upcomingRuns(of cron: CronExpression, count: Int) -> [Date] {
        var runs: [Date] = []
        var cursor = Date.now
        while runs.count < count, let next = cron.nextDate(after: cursor) {
            runs.append(next)
            cursor = next
        }
        return runs
    }

    private func save() {
        guard canSave else { return }
        var task = draft
        task.name = trimmedName
        task.prompt = trimmedPrompt
        task.cronExpression = draft.cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onConfirm {
            onConfirm(task)
        } else {
            appState.upsertScheduledTask(task)
            dismiss()
        }
    }

    private func cancel() {
        if let onConfirm {
            onConfirm(nil)
        } else {
            dismiss()
        }
    }
}
