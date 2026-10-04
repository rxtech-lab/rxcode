#if os(macOS)
import RxCodeCore
import RxCodeEditor
import SwiftUI

/// The "Swift Filter" section of the view editor. The script lives on the
/// draft view and is saved with it; a popover lets an agent write it.
struct TaskFilterScriptSection: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID
    @Binding var script: String?

    @State private var isPresented = false
    @State private var isGenerating = false

    private var hasScript: Bool {
        !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(hasScript ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                Text(hasScript ? "Filtered by Swift code" : "No Swift filter")
                    .foregroundStyle(hasScript ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                Spacer()
                if hasScript {
                    Button("Remove", role: .destructive) { script = nil }
                }
                Button {
                    isPresented = true
                } label: {
                    Label(hasScript ? "Edit…" : "Write Filter…", systemImage: "sparkles")
                }
                .accessibilityIdentifier("task-view-filter-script")
                // Refuse to close while an agent is writing the code, so the
                // result lands in front of the user.
                .popover(
                    isPresented: Binding(
                        get: { isPresented },
                        set: { if $0 || !isGenerating { isPresented = $0 } }
                    ),
                    arrowEdge: .trailing
                ) {
                    TaskFilterScriptPopover(
                        projectId: projectId,
                        script: $script,
                        isGenerating: $isGenerating,
                        onClose: { isPresented = false }
                    )
                    .environment(appState)
                    .interactiveDismissDisabled(isGenerating)
                }
            }
        } header: {
            Text("Swift Filter")
        } footer: {
            Text("Agent-written Swift that narrows the tasks and stories this view shows.")
        }
    }
}

/// Describe a filter, let the task suggestion agent write it, review or edit
/// the Swift, and apply it to the draft view. Code is compiled before it is
/// applied; code that doesn't build stays in the editor with the diagnostics.
struct TaskFilterScriptPopover: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID
    @Binding var script: String?
    @Binding var isGenerating: Bool
    let onClose: () -> Void
    var storyOnly = false

    @State private var requirement = ""
    @State private var code = ""
    @State private var isCompiling = false
    @State private var diagnostics: String?

    private let placeholderProvider = PredefinedAutocompleteProvider.placeholders([
        "includeTask", "includeStory", "FilterTask", "FilterStory",
        "title", "details", "status", "isDone", "tags", "version", "milestone",
        "priority", "type", "storyId", "storyTitle", "parentTaskId", "parentTaskIds", "hasAgent",
        "needsAttention", "taskCount", "doneTaskCount", "createdAt", "updatedAt",
    ])

    private var isBusy: Bool { isGenerating || isCompiling }

    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Swift filter")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text(storyOnly
                    ? "Describe which stories this card should show. An agent writes Swift that filters stories, and it's compiled before use."
                    : "Describe what this view should show. An agent writes Swift that filters its tasks and stories, and it's compiled before use.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 8) {
                TextField(
                    "e.g. Unfinished bugs tagged backend, updated this week",
                    text: $requirement,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isBusy)
                .onSubmit { generate() }

                Button(action: generate) {
                    HStack(spacing: 5) {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        } else {
                            Image(systemName: "sparkles")
                            Text("Generate")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("task-filter-script-generate")
            }

            CodeEditorView(
                text: $code,
                language: "swift",
                fontSize: ClaudeTheme.size(11),
                autocompleteProvider: placeholderProvider
            )
            .frame(height: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
            )
            .disabled(isGenerating)
            .overlay {
                if isGenerating {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("The agent is writing the filter…")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            if let diagnostics {
                ScrollView {
                    Text(verbatim: diagnostics)
                        .font(.system(size: ClaudeTheme.size(10), design: .monospaced))
                        .foregroundStyle(ClaudeTheme.statusError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
            }

            HStack {
                if code.isEmpty {
                    Button("Insert Example") { code = TaskFilterScript.starterScript }
                        .disabled(isBusy)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .disabled(isGenerating)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await apply(trimmedCode) }
                } label: {
                    if isCompiling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Use Filter")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || trimmedCode.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 520)
        .onAppear { code = script ?? "" }
    }

    // MARK: - Actions

    /// Asks the agent for code. The popover stays open until it answers; the
    /// result is compiled and shown for review before the user applies it.
    private func generate() {
        let requirement = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty, !isBusy else { return }
        isGenerating = true
        diagnostics = nil
        Task {
            let scopedRequirement = storyOnly
                ? "This filter controls the overview story card. Implement includeStory to choose visible stories. \(requirement)"
                : requirement
            let generated = await appState.generateTaskFilterScript(requirement: scopedRequirement, projectId: projectId)
            isGenerating = false
            guard let generated else {
                diagnostics = String(localized: "The agent didn't return any code. Try rephrasing the filter.")
                return
            }
            code = generated
            isCompiling = true
            let result = await appState.compileTaskFilterScript(generated)
            isCompiling = false
            if !result.success { diagnostics = result.diagnostics }
        }
    }

    /// Compiles `code` and hands it to the draft view when it builds. The
    /// view editor persists it on Save.
    private func apply(_ code: String) async {
        guard !code.isEmpty else { return }
        isCompiling = true
        diagnostics = nil
        let result = await appState.compileTaskFilterScript(code)
        isCompiling = false
        guard result.success else {
            diagnostics = result.diagnostics
            return
        }
        script = code
        onClose()
    }
}
#endif
