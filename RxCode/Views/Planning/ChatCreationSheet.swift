import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct ChatCreationActions: View {
    let sessionID: String
    let select: (ChatCreationIntent) -> Void

    var body: some View {
        Button { select(.init(.plan, sessionID: sessionID)) } label: {
            Label("Create Plan from Chat…", systemImage: "list.bullet.rectangle")
        }
        Button { select(.init(.task, sessionID: sessionID)) } label: {
            Label("Create Task from Chat…", systemImage: "checkmark.square")
        }
        Button { select(.init(.story, sessionID: sessionID)) } label: {
            Label("Create Story from Chat…", systemImage: "square.stack.3d.up")
        }
    }
}

struct ChatCreationMenu: View {
    @Environment(WindowState.self) private var window
    var body: some View {
        if let id = window.currentSessionId {
            Menu {
                ChatCreationActions(sessionID: id) { window.chatCreationIntent = $0 }
            } label: {
                Label("Create from Chat", systemImage: "square.and.pencil")
            }
            .fixedSize()
            .help("Create a plan, task, or story from this chat")
            .accessibilityIdentifier("create-from-chat")
        }
    }
}

struct ChatCreationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var window
    @Environment(\.dismiss) private var dismiss
    let intent: ChatCreationIntent
    @State private var source: ChatCreationSource?
    @State private var error: String?

    var body: some View {
        Group {
            if let source {
                switch intent.kind {
                case .plan: CodingPlanSetupSheet(source: source, goal: intent.goal)
                case .task, .story: ChatBoardCreationSheet(source: source, isStory: intent.kind == .story)
                }
            } else {
                VStack {
                    if let error {
                        ContentUnavailableView("Chat Unavailable", systemImage: "bubble.left", description: Text(error))
                        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    } else {
                        ProgressView("Reading chat…")
                    }
                }
                .padding()
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            }
        }
        .task(id: intent.id) {
            do { source = try await appState.chatCreationSource(intent, in: window) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Draft first, then hand the editable record to the same creation form used
/// by the project board. A global chat can target any workspace project.
private struct ChatBoardCreationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let source: ChatCreationSource
    let isStory: Bool
    @State private var projectID: UUID?
    @State private var model: AgentModel
    @State private var draft: TaskBoardSheet?
    @State private var generating = false
    @State private var error: String?

    init(source: ChatCreationSource, isStory: Bool) {
        self.source = source
        self.isStory = isStory
        _projectID = State(initialValue: source.project.isGlobalChat ? nil : source.project.id)
        _model = State(initialValue: source.model)
    }

    private var project: Project? {
        appState.projects.first { $0.id == projectID } ?? appState.projects.first
    }

    var body: some View {
        if let draft, let project {
            TaskFormSheet(payload: draft, defaultProjectId: project.id)
        } else {
            NavigationStack {
                Group {
                    if source.transcript.isEmpty {
                        ContentUnavailableView("No Chat Messages", systemImage: "bubble.left", description: Text("Send a message in this chat to create a draft from it."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let project {
                        Form {
                            Section {
                                LabeledContent("Source chat", value: source.summary?.title ?? "Chat")
                                Picker("Project", selection: Binding(get: { project.id }, set: { projectID = $0 })) {
                                    ForEach(appState.projects) { Text($0.name).tag($0.id) }
                                }
                                PlanModelPicker(title: "Drafting model", model: $model)
                            }
                        }
                        .formStyle(.grouped)
                        .disabled(generating)
                    } else {
                        ContentUnavailableView("No Projects", systemImage: "folder", description: Text("Add a workspace project to create a board item."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle(isStory ? "Create Story from Chat" : "Create Task from Chat")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Generate Draft") { generating = true }
                            .disabled(generating || source.transcript.isEmpty || project == nil)
                            .accessibilityIdentifier("chat-board-generate")
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 360, maxHeight: .infinity)
            .overlay { if generating { PlanningProgress(label: "Drafting from chat…") } }
            .planningError($error)
            .task(id: generating) {
                guard generating, let project else { return }
                defer { generating = false }
                do {
                    if !isStory, let sourceID = source.summary?.id,
                       let existing = appState.linkedTask(forSessionId: sourceID, projectId: project.id) {
                        draft = .task(existing)
                        return
                    }
                    let record = try await appState.boardDraftFromChat(source, isStory: isStory, project: project, model: model)
                    try Task.checkCancellation()
                    draft = record
                } catch where !Task.isCancelled { self.error = error.localizedDescription }
                catch {}
            }
        }
    }
}
