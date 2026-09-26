import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - New project

/// Where a new project's task board lives.
enum ProjectLocation: String, CaseIterable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .local: return "This Mac"
        case .cloud: return "Cloud"
        }
    }

    var systemImage: String {
        switch self {
        case .local: return "laptopcomputer"
        case .cloud: return "icloud"
        }
    }
}

/// Creates a project from a folder, either local to this Mac or synced to
/// every signed-in device through Autopilot.
struct NewProjectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var folder: URL?
    @State private var location: ProjectLocation
    @State private var showFolderPicker = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(prefersCloud: Bool = false) {
        _location = State(initialValue: prefersCloud ? .cloud : .local)
    }

    private var canCreate: Bool {
        folder != nil && !isCreating && (location == .local || appState.isSignedIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.system(size: ClaudeTheme.size(16), weight: .semibold))

            field("Folder") {
                HStack(spacing: 8) {
                    Text(folder?.path ?? String(localized: "No folder selected"))
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(folder == nil ? ClaudeTheme.textTertiary : ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { showFolderPicker = true }
                }
            }

            field("Name") {
                TextField(folder?.lastPathComponent ?? String(localized: "Project name"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Location") {
                Picker("Location", selection: $location) {
                    ForEach(ProjectLocation.allCases) { location in
                        Label(location.title, systemImage: location.systemImage).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("new-project-location")

                Text(locationHint)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(location == .cloud && !appState.isSignedIn ? ClaudeTheme.statusError : ClaudeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .accessibilityIdentifier("new-project-create")
            }
        }
        .padding(20)
        .frame(width: 420)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                folder = url
            }
        }
    }

    private var locationHint: LocalizedStringKey {
        switch location {
        case .local:
            return "Tasks and stories stay on this Mac."
        case .cloud:
            return appState.isSignedIn
                ? "Tasks and stories sync through Autopilot to every device signed in to your account."
                : "Sign in to Autopilot in Settings to create cloud projects."
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func create() {
        guard let folder, canCreate else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                let project = try await appState.createProject(
                    name: name,
                    folder: folder,
                    cloud: location == .cloud,
                    in: windowState
                )
                if let project, windowState.showingTasks {
                    windowState.taskDetailProjectId = project.id
                }
                dismiss()
            } catch {
                // The project was added locally; only the cloud link failed.
                errorMessage = String(localized: "The project was added on this Mac, but it couldn't be synced to the cloud: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Menu items

/// Cloud actions for a project: sync it to the cloud, link it to an existing
/// Autopilot project, sync now, or make it local again. Shared by the sidebar,
/// the task-board menus and `ProjectCloudButton`.
struct ProjectCloudMenuItems: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let project: Project

    var body: some View {
        if !appState.isSignedIn {
            Text("Sign in to Autopilot in Settings to sync projects to the cloud.")
        } else if project.isCloud {
            Button {
                appState.scheduleCloudBoardSync(for: project.id, delay: .zero)
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud")
            }

            Button {
                Task { await appState.disableCloudSync(for: project.id) }
            } label: {
                Label("Make Local Only", systemImage: "icloud.slash")
            }
        } else {
            Button {
                Task {
                    do {
                        try await appState.enableCloudSync(for: project.id)
                    } catch {
                        showError(String(localized: "Couldn't sync \(project.name) to the cloud: \(error.localizedDescription)"))
                    }
                }
            } label: {
                Label("Sync to Cloud", systemImage: "icloud.and.arrow.up")
            }

            // A sheet, presented by the window: these items also live in
            // context menus, which can't host one.
            Button {
                windowState.linkCloudProjectId = project.id
            } label: {
                Label("Link to Autopilot Project…", systemImage: "link.icloud")
            }
        }
    }

    private func showError(_ message: String) {
        windowState.errorMessage = message
        windowState.showError = true
    }
}

/// A visible entry point for a project's cloud state: shows whether the
/// project is local or in the cloud, and opens `ProjectCloudMenuItems`.
struct ProjectCloudButton: View {
    @Environment(AppState.self) private var appState

    let project: Project
    /// Icon-only, for the narrow overview cards.
    var compact = false

    var body: some View {
        let isSyncing = appState.cloudSyncingProjectIds.contains(project.id)
        let hasError = appState.cloudSyncError(for: project.id) != nil
        let icon = !project.isCloud ? "icloud.slash"
            : isSyncing ? "arrow.triangle.2.circlepath.icloud"
            : hasError ? "exclamationmark.icloud" : "icloud"
        Group {
            if compact {
                Menu {
                    ProjectCloudMenuItems(project: project)
                } label: {
                    Image(systemName: icon)
                        .foregroundStyle(hasError && !isSyncing ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(cloudHelpText)
                .accessibilityIdentifier("project-cloud-button-\(project.id.uuidString)")
            } else {
                Menu {
                    ProjectCloudMenuItems(project: project)
                } label: {
                    Label(project.isCloud ? "Cloud" : "Local", systemImage: icon)
                }
                .menuStyle(.button)
                .help(cloudHelpText)
                .accessibilityIdentifier("project-cloud-button-\(project.id.uuidString)")
            }
        }
        .fixedSize()
        .task(id: appState.isSignedIn) {
            // The link submenu lists Autopilot projects; load them once.
            if appState.isSignedIn && !appState.hasLoadedCloudProjects {
                await appState.refreshCloudProjects()
            }
        }
    }

    private var cloudHelpText: String {
        if let phase = appState.cloudSyncPhaseByProjectId[project.id] {
            return phase.progressText
        }
        return project.isCloud
            ? String(localized: "Cloud project: syncs through Autopilot. Click to sync now or make it local.")
            : String(localized: "Local project: stays on this Mac. Click to sync it to the cloud or link an Autopilot project.")
    }
}

// MARK: - Badge

/// A compact, determinate ring for the project detail's sync status.
struct ProjectCloudSyncRing: View {
    let phase: CloudProjectSyncPhase

    var body: some View {
        Group {
            if phase == .fetchingBoard {
                ProgressView()
                    .controlSize(.mini)
            } else {
                ZStack {
                    Circle()
                        .stroke(ClaudeTheme.textTertiary.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: phase.fractionCompleted)
                        .stroke(ClaudeTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: 14, height: 14)
        .animation(.easeInOut(duration: 0.2), value: phase.fractionCompleted)
        .help(phase.progressText)
        .accessibilityLabel(phase.progressText)
        .accessibilityIdentifier("project-detail-sync-progress")
    }
}

/// A small cloud glyph next to a cloud project's name, with the sync state in
/// its tooltip. Renders nothing for local projects.
struct ProjectCloudBadge: View {
    @Environment(AppState.self) private var appState

    let project: Project
    var size: CGFloat = 11

    var body: some View {
        if project.isCloud {
            let isSyncing = appState.cloudSyncingProjectIds.contains(project.id)
            let error = appState.cloudSyncError(for: project.id)
            Image(systemName: isSyncing ? "arrow.triangle.2.circlepath.icloud" : (error != nil ? "exclamationmark.icloud" : "icloud"))
                .font(.system(size: ClaudeTheme.size(size)))
                .foregroundStyle(error != nil && !isSyncing ? ClaudeTheme.statusError : ClaudeTheme.textTertiary)
                .symbolEffect(.pulse, isActive: isSyncing)
                .help(helpText(error: error))
                .accessibilityIdentifier("project-cloud-badge-\(project.id.uuidString)")
        }
    }

    private func helpText(error: String?) -> String {
        if !appState.isSignedIn {
            return String(localized: "Cloud project. Sign in to Autopilot to sync.")
        }
        if let phase = appState.cloudSyncPhaseByProjectId[project.id] {
            return phase.progressText
        }
        if let error {
            return String(localized: "Cloud sync failed: \(error)")
        }
        if let date = appState.cloudLastSyncedAt(for: project.id) {
            return String(localized: "Cloud project. Last synced \(date.formatted(.relative(presentation: .named))).")
        }
        return String(localized: "Cloud project. Syncs through Autopilot.")
    }
}

// MARK: - Unopened cloud project

/// A cloud project from another device that has no folder on this Mac yet.
/// Its board syncs once it is opened in a folder or linked to a project.
struct CloudProjectCard: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let cloud: CloudProject

    @State private var showFolderPicker = false

    private var linkableProjects: [Project] {
        appState.projects.filter { !$0.isCloud }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "icloud")
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text(cloud.title)
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.setCloudProject(cloud.id, hidden: true)
                    }
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Hide this cloud project. Show it again from the Hidden menu.")
                .accessibilityLabel("Hide Cloud Project")
                .accessibilityIdentifier("cloud-project-hide-\(cloud.id)")
            }
            if let repo = cloud.repositoryFullName, repo != cloud.title {
                Text(repo)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
            Text("In the cloud. Open it in a folder on this Mac to see and run its tasks.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Open on This Mac…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityIdentifier("cloud-project-open-\(cloud.id)")

                if !linkableProjects.isEmpty {
                    Menu {
                        ForEach(linkableProjects) { project in
                            Button(project.name) {
                                Task { await appState.linkProject(project.id, toCloudProject: cloud.id) }
                            }
                        }
                    } label: {
                        Text("Link to Project")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Sync an existing project on this Mac with this cloud project")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                if let project = await appState.openCloudProject(cloud, folder: url, in: windowState),
                   windowState.showingTasks {
                    windowState.taskDetailProjectId = project.id
                }
            }
        }
    }
}

// MARK: - Hidden cloud projects

/// Dropdown listing cloud projects hidden from the Tasks overview, so they
/// can be shown again. Renders nothing while none are hidden.
struct HiddenCloudProjectsMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let hidden = appState.hiddenUnopenedCloudProjects
        if !hidden.isEmpty {
            Menu {
                Section("Show Cloud Project") {
                    ForEach(hidden) { cloud in
                        Button(cloud.title) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appState.setCloudProject(cloud.id, hidden: false)
                            }
                        }
                    }
                }
                Divider()
                Button("Show All") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showAllHiddenCloudProjects()
                    }
                }
            } label: {
                Label("Hidden (\(hidden.count))", systemImage: "eye.slash")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Show cloud projects you hid from this page")
            .accessibilityIdentifier("task-board-hidden-cloud-projects-menu")
        }
    }
}

// MARK: - Link sheet

/// Links a local project to an existing Autopilot project, picked with a
/// type-to-search combobox. The two boards merge on the first sync.
struct LinkCloudProjectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let projectId: UUID

    @State private var search = ""
    @State private var selectionId: String?
    @State private var isLinking = false
    @State private var isRefreshing = false

    private var project: Project? {
        appState.projects.first { $0.id == projectId }
    }

    private var candidates: [CloudProject] { appState.unopenedCloudProjects }

    private var matches: [CloudProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.repositoryFullName?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selection: CloudProject? {
        candidates.first { $0.id == selectionId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link to Autopilot Project")
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                if let project {
                    Text("\(project.name)'s tasks and stories will merge with the Autopilot project's board and sync to every device signed in to your account.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            combo

            if let selection {
                selectedRow(selection)
            } else if appState.hasLoadedCloudProjects && candidates.isEmpty {
                Text("Every Autopilot project on your account is already linked on this Mac. Use Sync to Cloud to create a new one.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .help("Reload your Autopilot projects")

                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || isLinking)
                    .accessibilityIdentifier("link-cloud-project-confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            if !appState.hasLoadedCloudProjects { await refresh() }
            // Suggest the Autopilot project tracking the same repository.
            if selectionId == nil, let repo = project?.gitHubRepo {
                selectionId = candidates.first { $0.matchesRepository(repo) }?.id
            }
        }
    }

    /// A search field whose suggestions are the matching Autopilot projects,
    /// plus a browse menu, like the task form's "Starts after" combo.
    private var combo: some View {
        HStack(spacing: 6) {
            TextField("Autopilot project", text: $search, prompt: Text(
                appState.hasLoadedCloudProjects ? "Search Autopilot projects" : "Loading Autopilot projects…"
            ))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .onChange(of: search) { _, value in
                // Choosing a suggestion completes the field with its id.
                if let picked = candidates.first(where: { $0.id == value }) {
                    pick(picked)
                }
            }
            .onSubmit {
                if matches.count == 1 { pick(matches[0]) }
                else if selection != nil { link() }
            }
            .textInputSuggestions {
                ForEach(matches) { cloud in
                    suggestionLabel(cloud)
                        .frame(width: 380, alignment: .leading)
                        .textInputCompletion(cloud.id)
                }
            }
            .accessibilityIdentifier("link-cloud-project-search")

            Menu {
                if candidates.isEmpty {
                    Text(appState.hasLoadedCloudProjects ? "No unlinked Autopilot projects" : "Loading Autopilot projects…")
                }
                ForEach(candidates) { cloud in
                    Button(cloud.title) { pick(cloud) }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Browse Autopilot projects")
            .accessibilityLabel("Browse Autopilot projects")
        }
    }

    private func suggestionLabel(_ cloud: CloudProject) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(cloud.title)
                if let repo = cloud.repositoryFullName, repo != cloud.title {
                    Text(repo)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
        } icon: {
            Image(systemName: cloud.type == "github" ? "chevron.left.forwardslash.chevron.right" : "icloud")
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    private func selectedRow(_ cloud: CloudProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cloud.type == "github" ? "chevron.left.forwardslash.chevron.right" : "icloud")
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(cloud.title)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                if let detail = cloud.repositoryFullName ?? cloud.description, !detail.isEmpty, detail != cloud.title {
                    Text(detail)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                selectionId = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Clear selection")
        }
        .padding(10)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.5), in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
    }

    private func pick(_ cloud: CloudProject) {
        selectionId = cloud.id
        search = ""
    }

    private func refresh() async {
        isRefreshing = true
        await appState.refreshCloudProjects()
        isRefreshing = false
    }

    private func link() {
        guard let selection, !isLinking else { return }
        isLinking = true
        Task {
            await appState.linkProject(projectId, toCloudProject: selection.id)
            dismiss()
        }
    }
}
