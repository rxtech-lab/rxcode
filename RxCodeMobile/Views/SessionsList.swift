import RxCodeCore
import RxCodeSync
import SwiftUI

enum MobileDraftSessionID {
    private static let prefix = "draft-new"

    static func make(projectID: UUID) -> String {
        "\(prefix):\(projectID.uuidString):\(UUID().uuidString)"
    }

    static func projectID(from id: String) -> UUID? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    static func isDraft(_ id: String) -> Bool {
        projectID(from: id) != nil
    }
}

struct SessionsList: View {
    @EnvironmentObject private var state: MobileAppState
    let projectID: UUID
    @Binding var selected: String?
    var usesSelection = true
    @State private var searchText = ""
    @State private var showingNewThread = false
    @Namespace private var glassNamespace

    /// Number of rows currently materialized. The list grows in `pageSize`
    /// increments as the user scrolls so we never render every thread at once.
    @State private var displayLimit = SessionsList.pageSize
    private static let pageSize = 20

    var body: some View {
        glassThreadList
            .navigationTitle("Threads")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingNewThread) {
                NewThreadSheet(projectID: projectID) { newSessionID in
                    selected = newSessionID
                }
                .environmentObject(state)
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search threads"
            )
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .onChange(of: searchText) { _, _ in
                // Restart paging so search results always begin at the top.
                displayLimit = Self.pageSize
            }
            .overlay {
                if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filtered.isEmpty && searchText.isEmpty {
                    emptyStateView
                }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingNewThread = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
            }
        }
    }

    // MARK: - Glass Thread List

    private var glassThreadList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                GlassEffectContainer(spacing: 12) {
                    ForEach(visible) { session in
                        GlassThreadCard(
                            session: session,
                            isSelected: selected == session.id,
                            usesNavigationLink: !usesSelection,
                            onSelect: usesSelection ? { selected = session.id } : nil
                        )
                        .glassEffectID(session.id, in: glassNamespace)
                        .onAppear {
                            if session.id == visible.last?.id { loadMore() }
                        }
                        .contextMenu {
                            threadContextMenu(for: session)
                        }
                    }
                }

                if displayLimit < filtered.count {
                    loadingIndicator
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.spring(duration: 0.3), value: filtered.map(\.id))
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func threadContextMenu(for session: SessionSummary) -> some View {
        Button {
            Task { await state.archiveThread(sessionID: session.id) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }

        Divider()

        Button(role: .destructive) {
            Task { await state.deleteThread(sessionID: session.id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Loading Indicator

    private var loadingIndicator: some View {
        HStack {
            Spacer()
            ProgressView()
                .padding(.vertical, 20)
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No Threads")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Start a new conversation to get help with your project.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showingNewThread = true
            } label: {
                Label("New Thread", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The slice of `filtered` currently rendered.
    private var visible: [SessionSummary] {
        Array(filtered.prefix(displayLimit))
    }

    private func loadMore() {
        guard displayLimit < filtered.count else { return }
        displayLimit = min(displayLimit + Self.pageSize, filtered.count)
    }

    private var filtered: [SessionSummary] {
        let query = searchText.lowercased()
        return state.sessions
            .filter { session in
                guard session.projectId == projectID, !session.isArchived else { return false }
                if query.isEmpty { return true }
                let title = ChatSession.stripAttachmentMarkers(from: session.title).lowercased()
                return title.contains(query)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }
}

struct MobileRunProfilesView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var editingProfile: RunProfile?

    private var project: Project? {
        state.projects.first { $0.id == projectID }
    }

    private var profiles: [RunProfile] {
        state.runProfiles(for: projectID).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var tasks: [MobileRunTaskSnapshot] {
        state.runTasks(for: projectID)
    }

    var body: some View {
        List {
            if !tasks.isEmpty {
                Section("Runs") {
                    ForEach(tasks) { task in
                        runTaskRow(task)
                    }
                }
            }

            Section("Profiles") {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No Run Profiles",
                        systemImage: "play.rectangle",
                        description: Text("Create a profile to run a command on your Mac.")
                    )
                } else {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
        .navigationTitle(project?.name ?? "Run Profiles")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingProfile = Self.newProfile(projectID: projectID)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await state.refreshSnapshot()
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                MobileRunProfileEditorView(profile: profile, projectID: projectID)
                    .environmentObject(state)
            }
        }
        .alert("Run Profile Error", isPresented: Binding(
            get: { state.lastRunProfileError != nil },
            set: { if !$0 { state.lastRunProfileError = nil } }
        )) {
            Button("OK", role: .cancel) { state.lastRunProfileError = nil }
        } message: {
            Text(state.lastRunProfileError ?? "")
        }
    }

    private func profileRow(_ profile: RunProfile) -> some View {
        let task = state.runningTask(projectID: projectID, profileID: profile.id)
        return HStack(spacing: 12) {
            Image(systemName: iconName(for: profile.type))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                    .lineLimit(1)
                Text(profileSubtitle(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let task {
                Button {
                    Task { await state.stopRunTask(task) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button {
                    Task { await state.runProfile(projectID: projectID, profileID: profile.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingProfile = profile
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await state.deleteRunProfile(projectID: projectID, profileID: profile.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Edit") { editingProfile = profile }
            Button("Duplicate") {
                var copy = profile
                copy.id = UUID()
                copy.name = profile.name + " (copy)"
                copy.createdAt = Date()
                copy.updatedAt = Date()
                Task { await state.saveRunProfile(copy, projectID: projectID) }
            }
            Button("Delete", role: .destructive) {
                Task { await state.deleteRunProfile(projectID: projectID, profileID: profile.id) }
            }
        }
    }

    private func runTaskRow(_ task: MobileRunTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(task.profileName, systemImage: task.isRunning ? "play.circle.fill" : "checkmark.circle")
                    .foregroundStyle(task.isRunning ? Color.accentColor : .secondary)
                Spacer()
                Text(task.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !task.commandPreview.isEmpty {
                Text(task.commandPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let output = task.terminalOutputTail, !output.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }

            if task.isRunning {
                Button(role: .destructive) {
                    Task { await state.stopRunTask(task) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func iconName(for type: RunProfileType) -> String {
        switch type {
        case .bash: return "terminal"
        case .xcode: return "hammer.fill"
        case .make: return "wrench.and.screwdriver.fill"
        }
    }

    private func profileSubtitle(_ profile: RunProfile) -> String {
        switch profile.type {
        case .bash:
            return profile.bash.command.isEmpty ? "Bash command" : profile.bash.command
        case .xcode:
            let xcode = profile.xcode ?? XcodeRunConfig()
            return [xcode.container, xcode.scheme, xcode.action.rawValue].filter { !$0.isEmpty }.joined(separator: " · ")
        case .make:
            let make = profile.make ?? MakeRunConfig()
            return ["make", make.target, make.arguments].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private static func newProfile(projectID: UUID) -> RunProfile {
        let now = Date()
        return RunProfile(
            projectId: projectID,
            name: "New Bash Configuration",
            type: .bash,
            bash: BashRunConfig(),
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - Previews

#if DEBUG
extension MobileAppState {
    /// A preview-ready MobileAppState with sample projects and sessions.
    static var preview: MobileAppState {
        let state = MobileAppState()
        let projectID = UUID()
        
        state.projects = [
            Project(id: projectID, name: "RxCode", path: "/Users/dev/RxCode")
        ]
        
        state.sessions = [
            SessionSummary(
                id: "session-1",
                projectId: projectID,
                title: "Building new feature module",
                updatedAt: Date(),
                isPinned: false,
                isArchived: false,
                isStreaming: true,
                attention: nil,
                todos: [
                    TodoItem(id: 1, content: "Create models", activeForm: "Creating models", status: .completed),
                    TodoItem(id: 2, content: "Add views", activeForm: "Adding views", status: .inProgress),
                    TodoItem(id: 3, content: "Write tests", activeForm: "Writing tests", status: .pending)
                ],
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-2",
                projectId: projectID,
                title: "Implement Liquid Glass UI",
                updatedAt: Date().addingTimeInterval(-300),
                isPinned: true,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: [
                    TodoItem(id: 1, content: "Task 1", activeForm: "Doing task 1", status: .completed),
                    TodoItem(id: 2, content: "Task 2", activeForm: "Doing task 2", status: .completed),
                    TodoItem(id: 3, content: "Task 3", activeForm: "Doing task 3", status: .completed)
                ],
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-3",
                projectId: projectID,
                title: "Deploy to production",
                updatedAt: Date().addingTimeInterval(-120),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: .permission,
                todos: nil,
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-4",
                projectId: projectID,
                title: "Code review assistance",
                updatedAt: Date().addingTimeInterval(-600),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: .question,
                todos: nil,
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-5",
                projectId: projectID,
                title: "Fix scrolling performance",
                updatedAt: Date().addingTimeInterval(-3600),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: nil,
                hasUncheckedCompletion: true
            ),
            SessionSummary(
                id: "session-6",
                projectId: projectID,
                title: "Review pull request",
                updatedAt: Date().addingTimeInterval(-86400),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: nil,
                hasUncheckedCompletion: false
            )
        ]
        
        return state
    }
    
    /// A preview-ready MobileAppState with no sessions (empty state).
    static var previewEmpty: MobileAppState {
        let state = MobileAppState()
        let projectID = UUID()
        
        state.projects = [
            Project(id: projectID, name: "New Project", path: "/Users/dev/NewProject")
        ]
        state.sessions = []
        
        return state
    }
}
#endif

#Preview("Sessions List") {
    let state = MobileAppState.preview
    let projectID = state.projects.first!.id
    
    return NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(nil)
        )
    }
    .environmentObject(state)
}

#Preview("Sessions List - With Selection") {
    let state = MobileAppState.preview
    let projectID = state.projects.first!.id
    let selectedID = state.sessions.first?.id
    
    return NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(selectedID),
            usesSelection: true
        )
    }
    .environmentObject(state)
}

#Preview("Sessions List - Empty") {
    let state = MobileAppState.previewEmpty
    let projectID = state.projects.first!.id
    
    return NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(nil)
        )
    }
    .environmentObject(state)
}

private struct MobileRunProfileEditorView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RunProfile
    let projectID: UUID

    init(profile: RunProfile, projectID: UUID) {
        self._draft = State(initialValue: profile)
        self.projectID = projectID
    }

    var body: some View {
        Form {
            Section("Configuration") {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: Binding(
                    get: { draft.type },
                    set: { type in
                        draft.type = type
                        if type == .xcode, draft.xcode == nil { draft.xcode = XcodeRunConfig() }
                        if type == .make, draft.make == nil { draft.make = MakeRunConfig() }
                    }
                )) {
                    Text("Bash").tag(RunProfileType.bash)
                    Text("Xcode").tag(RunProfileType.xcode)
                    Text("Make").tag(RunProfileType.make)
                }
            }

            switch draft.type {
            case .bash:
                bashSection
            case .xcode:
                xcodeSection
            case .make:
                makeSection
            }
        }
        .navigationTitle(draft.name.isEmpty ? "Run Profile" : draft.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = draft
                    saved.projectId = projectID
                    saved.updatedAt = Date()
                    Task {
                        await state.saveRunProfile(saved, projectID: projectID)
                        dismiss()
                    }
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var bashSection: some View {
        Section("Command") {
            TextEditor(text: $draft.bash.command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
            TextField("Working Directory", text: $draft.bash.workingDirectory, prompt: Text("Project root"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }

    private var xcodeSection: some View {
        Section("Xcode") {
            let xcode = Binding(
                get: { draft.xcode ?? XcodeRunConfig() },
                set: { draft.xcode = $0 }
            )
            TextField("Project / Workspace", text: xcode.container, prompt: Text("App.xcodeproj"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Toggle("Use Workspace", isOn: xcode.isWorkspace)
            TextField("Scheme", text: xcode.scheme)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            TextField("Configuration", text: xcode.configuration)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Picker("Action", selection: xcode.action) {
                ForEach(XcodeAction.allCases, id: \.self) { action in
                    Text(action.rawValue.capitalized).tag(action)
                }
            }
            TextField("Destination", text: xcode.destination, prompt: Text("Optional xcodebuild destination"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }

    private var makeSection: some View {
        Section("Make") {
            let make = Binding(
                get: { draft.make ?? MakeRunConfig() },
                set: { draft.make = $0 }
            )
            TextField("Makefile", text: make.makefile, prompt: Text("Makefile"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            TextField("Target", text: make.target)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            TextField("Arguments", text: make.arguments)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            TextField("Working Directory", text: $draft.bash.workingDirectory, prompt: Text("Project root"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }
}
