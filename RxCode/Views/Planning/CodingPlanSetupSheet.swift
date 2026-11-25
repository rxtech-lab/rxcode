import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct PlanModelPicker: View {
    @Environment(AppState.self) private var appState
    let title: String
    @Binding var model: AgentModel

    var body: some View {
        Picker(title, selection: Binding(get: { model.key }, set: { key in
            if let choice = appState.codingModelSections.flatMap(\.models).first(where: { $0.key == key }) {
                model = choice
            }
        })) {
            let sections = appState.codingModelSections
            if !sections.contains(where: { $0.models.contains(where: { $0.key == model.key }) }) {
                Text(model.displayName).tag(model.key)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { choice in
                        Text(choice.displayName).tag(choice.key)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(title)
    }
}

struct CodingPlanSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var window
    @Environment(\.dismiss) private var dismiss
    let source: ChatCreationSource
    @State private var projectID: UUID
    @State private var goal: String
    @State private var configuration: CodingPlan.Configuration
    @State private var reviewerEditor: CodingPlan.Reviewer?
    @State private var starting = false
    @State private var error: String?

    init(source: ChatCreationSource, goal: String) {
        self.source = source
        _projectID = State(initialValue: source.project.id)
        _goal = State(initialValue: MarkdownDescriptionEditor.markdown(forChatDraft: goal, files: source.draftFiles))
        _configuration = State(initialValue: .init(planner: source.model, reviewers: [
            .init(model: source.model, prompt: "Review feasibility, edge cases, and verification.")
        ]))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Planning request") {
                    if source.project.isGlobalChat {
                        Picker("Project", selection: $projectID) {
                            ForEach(appState.projects + [appState.globalChatProject]) { Text($0.name).tag($0.id) }
                        }
                    }
                    MarkdownDescriptionEditor(
                        text: $goal,
                        placeholder: String(localized: "What should the plan cover?"),
                        isDisabled: starting,
                        height: 100,
                        identifierPrefix: "coding-plan-goal",
                        editorIdentifier: "coding-plan-goal"
                    )
                    if let title = source.summary?.title {
                        LabeledContent("Source chat", value: title)
                    }
                }
                Section {
                    PlanModelPicker(title: "Planner", model: $configuration.planner)
                        .accessibilityIdentifier("coding-plan-planner")
                    Toggle("Use planner as host", isOn: Binding(
                        get: { configuration.hostOverride == nil },
                        set: { configuration.hostOverride = $0 ? nil : configuration.planner }
                    ))
                    if configuration.hostOverride != nil {
                        PlanModelPicker(title: "Host", model: Binding(
                            get: { configuration.host }, set: { configuration.hostOverride = $0 }
                        ))
                    }
                } header: {
                    Text("Debate host")
                } footer: {
                    Text("The planner drafts first. The host sets a review agenda, then resolves the reviewers’ feedback into a final plan.")
                }
                Section("Reviewers") {
                    ForEach(Array(configuration.reviewers.enumerated()), id: \.element.id) { index, reviewer in
                        Button {
                            reviewerEditor = reviewer
                        } label: {
                            HStack {
                                Label("Reviewer \(index + 1)", systemImage: "person.crop.circle")
                                Spacer()
                                Text(appState.modelDisplayLabel(reviewer.model.id, provider: reviewer.model.provider))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("coding-plan-reviewer-\(index)")
                    }
                    Button {
                        reviewerEditor = .init(model: configuration.planner, prompt: "")
                    } label: {
                        Label("Add Reviewer…", systemImage: "plus")
                    }
                    .accessibilityIdentifier("coding-plan-add-reviewer")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Plan Mode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Debate") { start() }
                        .disabled(starting || (goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source.transcript.isEmpty))
                        .accessibilityIdentifier("coding-plan-start")
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 500, idealHeight: 560, maxHeight: .infinity)
        .interactiveDismissDisabled(starting)
        .disabled(starting)
        .overlay { if starting { PlanningProgress(label: "Starting debate…") } }
        .sheet(item: $reviewerEditor) { reviewer in
            let index = configuration.reviewers.firstIndex { $0.id == reviewer.id }
            CodingPlanReviewerSheet(reviewer: reviewer, title: index == nil ? "Add Reviewer" : "Reviewer",
                remove: index != nil && configuration.reviewers.count > 1 ? {
                    configuration.reviewers.removeAll { $0.id == reviewer.id }
                } : nil) { edited in
                if let index { configuration.reviewers[index] = edited }
                else { configuration.reviewers.append(edited) }
            }
        }
        .planningError($error)
    }

    private func start() {
        guard !starting, let project = appState.sessionProject(id: projectID) else { return }
        starting = true
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = text.isEmpty ? "Plan the requested work in “\(source.summary?.title ?? "Chat")”." : text
        Task {
            defer { starting = false }
            do {
                try await appState.startCodingPlan(goal: task, source: source.transcript, configuration: configuration,
                    project: project, worktreePath: source.project.id == projectID ? source.worktreePath : nil,
                    worktreeBranch: source.project.id == projectID ? source.worktreeBranch : nil, in: window)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CodingPlanReviewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var reviewer: CodingPlan.Reviewer
    let title: LocalizedStringKey
    var remove: (() -> Void)?
    let save: (CodingPlan.Reviewer) throws -> Void
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                PlanModelPicker(title: "Model", model: $reviewer.model)
                    .accessibilityIdentifier("coding-plan-reviewer-model")
                Section {
                    MarkdownDescriptionEditor(
                        text: $reviewer.prompt,
                        placeholder: String(localized: "What should this agent review?"),
                        title: "Review instructions",
                        height: 100,
                        identifierPrefix: "coding-plan-review-prompt",
                        editorIdentifier: "coding-plan-review-prompt"
                    )
                }
                if let remove {
                    Button("Remove Reviewer", role: .destructive) { remove(); dismiss() }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Reviewer") {
                        do {
                            try save(reviewer)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 340, maxHeight: .infinity)
        .planningError($error)
    }
}

struct PlanningProgress: View {
    let label: String
    var body: some View {
        ProgressView(label)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

extension View {
    func planningError(_ error: Binding<String?>) -> some View {
        alert("Couldn’t Complete Action", isPresented: Binding(
            get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(error.wrappedValue ?? "") }
    }
}
