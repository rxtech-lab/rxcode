import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// The project directory owns no split navigation; selecting a project opens its workspace.
struct FlowcyProjectsView: View {
    @Environment(MobileCloudState.self) private var cloud
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selected: CloudProject?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    @State private var showingOrder = false
    @State private var feedback: String?
    @AppStorage("mobile.flowcy.projectOrder") private var savedProjectOrders = Data()

    private var orderScope: String { cloud.accountID ?? "signed-in" }

    private var orderedProjects: [CloudProject] {
        let orders = (try? JSONDecoder().decode([String: [String]].self, from: savedProjectOrders)) ?? [:]
        let ranks = Dictionary((orders[orderScope] ?? []).enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        return cloud.projects.enumerated().sorted { lhs, rhs in
            let left = ranks[lhs.element.id] ?? Int.max
            let right = ranks[rhs.element.id] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private var projects: [CloudProject] {
        orderedProjects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            || ($0.repositoryFullName?.localizedCaseInsensitiveContains(search) ?? false) }
    }

    var body: some View {
        Group {
            if let selected {
                FlowcyProjectWorkspace(project: selected) {
                    MobileHaptics.buttonTap()
                    self.selected = nil
                }
            } else {
                directory
            }
        }
    }

    private var directory: some View {
        NavigationStack {
            Group {
                if loading && cloud.projects.isEmpty {
                    ProgressView("Loading projects…")
                } else if let error, cloud.projects.isEmpty {
                    ContentUnavailableView {
                        Label("Unable to Load Projects", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Retry") { Task { await reload() } }
                    }
                } else if projects.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Projects" : "No Matching Projects",
                                           systemImage: "folder",
                                           description: Text(search.isEmpty ? "Create a project to get started." : "Try another search."))
                } else if sizeClass == .regular {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], spacing: 16) {
                            ForEach(projects) { project in
                                projectButton(project)
                                    .padding(20)
                                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }.padding()
                    }
                    .background(Color(.systemGroupedBackground))
                    .refreshable { await reload() }
                } else {
                    List(projects) { project in projectButton(project) }
                        .refreshable { await reload() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Projects")
            .searchable(text: $search, prompt: "Search projects")
            .toolbar {
                FlowcyRemoteToolbar()
                ToolbarItem(placement: .primaryAction) {
                    Button("Reorder Projects", systemImage: "arrow.up.arrow.down") {
                        MobileHaptics.buttonTap()
                        showingOrder = true
                    }
                    .disabled(cloud.projects.count < 2)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Project", systemImage: "plus") {
                        MobileHaptics.buttonTap()
                        creating = true
                    }
                }
            }
            .sheet(isPresented: $creating) {
                FlowcyProjectForm { await reload() }.mobileSheetPresentation()
            }
            .sheet(isPresented: $showingOrder) {
                projectOrderSheet.mobileSheetPresentation()
            }
            .mobileStatusToast($feedback)
            .task { await reload() }
        }
    }

    private func projectButton(_ project: CloudProject) -> some View {
        Button {
            MobileHaptics.buttonTap()
            selected = project
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Label(project.title, systemImage: "folder").font(.headline).lineLimit(2)
                    Text(project.repositoryFullName ?? "Standalone project")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flowcy-project-\(project.id)")
        .accessibilityHint("Opens the project. Long press and drag to reorder.")
        .draggable("flowcy-project:\(project.id)")
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix("flowcy-project:") else { return false }
            let moved = String(item.dropFirst("flowcy-project:".count))
            var order = orderedProjects
            guard moved != project.id,
                  let source = order.firstIndex(where: { $0.id == moved }),
                  let target = order.firstIndex(where: { $0.id == project.id }) else { return false }
            order.insert(order.remove(at: source), at: target)
            saveOrder(order)
            return true
        }
    }

    private var projectOrderSheet: some View {
        NavigationStack {
            List {
                ForEach(orderedProjects) { project in
                    Label(project.title, systemImage: "folder")
                }
                .onMove { source, destination in
                    var order = orderedProjects
                    order.move(fromOffsets: source, toOffset: destination)
                    saveOrder(order)
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if orderedProjects.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "folder")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Reorder Projects")
            .navigationBarTitleDisplayMode(.inline)
            .mobileStatusToast($feedback)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        MobileHaptics.buttonTap()
                        showingOrder = false
                    }
                }
            }
        }
    }

    private func saveOrder(_ projects: [CloudProject]) {
        var orders = (try? JSONDecoder().decode([String: [String]].self, from: savedProjectOrders)) ?? [:]
        orders[orderScope] = projects.map(\.id)
        guard let data = try? JSONEncoder().encode(orders) else { return }
        withAnimation(.snappy) { savedProjectOrders = data }
        MobileHaptics.buttonTap()
        feedback = "Project order saved"
    }

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do { try await state.refreshCloudTaskProjects() }
        catch { self.error = error.localizedDescription }
    }
}

enum FlowcyProjectSection: String, CaseIterable, Identifiable {
    case overview = "Overview", tasks = "Tasks", docs = "Documentation"
    case issues = "Issues", pullRequests = "Pull Requests", sessions = "Agent Chat"
    case actions = "CI", updates = "Dependency & CI Updates", releases = "Releases", secrets = "Secrets"
    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tasks: "checklist"
        case .docs: "book"
        case .issues: "exclamationmark.circle"
        case .pullRequests: "arrow.triangle.pull"
        case .sessions: "bubble.left.and.bubble.right"
        case .actions: "gearshape.2"
        case .updates: "arrow.triangle.2.circlepath"
        case .releases: "shippingbox"
        case .secrets: "key"
        }
    }
}

enum FlowcyProjectQuickAction: String, Identifiable {
    case release, ci, dependencies
    var id: Self { self }
    var section: FlowcyProjectSection { self == .release ? .releases : .updates }
    var repoAction: MobileCIRepoAction? {
        switch self {
        case .release: nil
        case .ci: .scanCI
        case .dependencies: .scanDependencies
        }
    }
}

private struct FlowcyProjectWorkspace: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.flowcyRemoteActions) private var remoteActions
    let project: CloudProject
    let onClose: () -> Void
    @State private var selection: FlowcyProjectSection? = .overview
    @State private var quickAction: FlowcyProjectQuickAction?
    @State private var quickToast: String?

    private var sections: [FlowcyProjectSection] {
        project.repositoryFullName == nil ? [.overview, .tasks, .docs] : FlowcyProjectSection.allCases
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Project") {
                    sidebarLinks([.overview, .tasks, .docs])
                }
                if project.repositoryFullName != nil {
                    Section("Collaboration") {
                        sidebarLinks([.issues, .pullRequests, .sessions])
                    }
                    Section("Delivery") {
                        sidebarLinks([.actions, .updates, .releases])
                    }
                    Section("Security") {
                        sidebarLinks([.secrets])
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(project.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Projects", systemImage: "chevron.left", action: onClose)
                        .accessibilityIdentifier("flowcy-close-project")
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            NavigationStack {
                Group {
                    if let selection { destination(selection) }
                    else {
                        ContentUnavailableView("Select a Feature", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .toolbar { FlowcyRemoteToolbar() }
            }
            // A sidebar selection owns its entire stack, including pushed resource details.
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .mobileStatusToast($quickToast)
        .onChange(of: selection) { _, _ in MobileHaptics.buttonTap() }
        .sheet(item: $quickAction) { action in
            NavigationStack {
                FlowcyProjectRepositoryView(project: project, section: action.section, isQuickAction: true, repoAction: action.repoAction,
                                            onQuickActionFinished: { quickToast = $0 })
                    .toolbar {
                        // The release picker has its own Cancel; CI actions own the trailing menu.
                        if action != .release {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { MobileHaptics.buttonTap(); quickAction = nil }
                            }
                        }
                    }
            }.mobileSheetPresentation()
        }
    }

    private func sidebarLinks(_ sections: [FlowcyProjectSection]) -> some View {
        ForEach(sections) { section in
            NavigationLink(value: section) { Label(section.rawValue, systemImage: section.icon) }
                .accessibilityIdentifier("flowcy-section-\(section.id)")
        }
    }

    @ViewBuilder private func destination(_ section: FlowcyProjectSection) -> some View {
        switch section {
        case .overview:
            FlowcyProjectOverview(project: project, sections: sections, navigate: { section in
                selection = section
            }, openAction: openAction)
        case .tasks:
            if let local = state.taskProjects.first(where: { $0.cloudId == project.id }) {
                MobileTaskBoardView(projectID: local.id, onOpenChat: { _ in remoteActions?.open() }, isModal: false)
                    .modifier(MobileTaskDestinations(onOpenChat: { _ in remoteActions?.open() }))
            } else {
                ContentUnavailableView("Project Unavailable", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .actions:
            if let repository = project.repositoryFullName {
                FlowcyCIStatusView(repositoryFullName: repository)
            }
        case .issues, .pullRequests, .sessions:
            FlowcyResourceView(title: section.rawValue, path: resourcePath(section), repositoryFullName: project.repositoryFullName)
        default:
            FlowcyProjectRepositoryView(project: project, section: section)
        }
    }

    private func openAction(_ action: FlowcyProjectQuickAction) {
        MobileHaptics.buttonTap()
        quickAction = action
    }

    private func resourcePath(_ section: FlowcyProjectSection) -> String {
        switch section {
        case .issues: "issues"
        case .pullRequests: "pull-requests"
        default: "sessions?paginated=true"
        }
    }
}

/// Resolve an existing feature registration before opening its dedicated detail screen.
private struct FlowcyProjectRepositoryView: View {
    @EnvironmentObject private var state: MobileAppState
    let project: CloudProject
    let section: FlowcyProjectSection
    var isQuickAction = false
    var repoAction: MobileCIRepoAction? = nil
    /// Reports a finished quick action after its sheet closes itself.
    var onQuickActionFinished: ((String) -> Void)? = nil
    @State private var docs: DocsRepo?
    @State private var release: ReleaseRepo?
    @State private var watched: WatchedRepo?
    @State private var ciOverview: CIRepositoryOverview?
    @State private var releaseWorkflows: [MobileReleaseWorkflow] = []
    @State private var releaseStatus: String?
    @State private var showingSetup = false
    @State private var setupAction: MobileCIRepoAction?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if section == .secrets, let repository = project.repositoryFullName {
                MobileSecretsRepoView(repoFullName: repository)
            } else if let docs { MobileDocsRepoDetailView(repo: docs) }
            else if let release {
                if isQuickAction {
                    MobileReleaseWorkflowPicker(repo: release, workflows: releaseWorkflows) { message in
                        MobileHaptics.connected()
                        onQuickActionFinished?(message)
                    }
                } else { MobileReleaseRepoDetailView(repo: release) { await load() } }
            }
            else if let watched {
                // Re-identify after setup so a freshly watched repository opens its automation settings.
                MobileCIRepoDetailView(repo: watched, overview: ciOverview, initialAction: repoAction ?? setupAction) { await load() }
                    .id(watched.id + (setupAction?.rawValue ?? ""))
            }
            else if loading { ProgressView("Loading project…") }
            else {
                ContentUnavailableView {
                    Label(error == nil ? "Feature Not Configured" : "Unable to Load Feature", systemImage: section.icon)
                } description: {
                    Text(error ?? "This repository is not registered for \(section.rawValue.lowercased()) in your Flowcy account. Set it up to get started.")
                } actions: {
                    if error != nil { Button("Retry") { Task { await load() } } }
                    if error == nil, project.repositoryFullName != nil,
                       section == .releases || section == .updates {
                        Button("Set Up \(section.rawValue)") {
                            MobileHaptics.buttonTap()
                            showingSetup = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(section.rawValue)
        .overlay(alignment: .topTrailing) {
            if let releaseStatus {
                Label(releaseStatus, systemImage: "checkmark.circle.fill")
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
        }
        .sheet(isPresented: $showingSetup) {
            FlowcyProjectFeatureSetup(project: project, section: section) {
                // Like the dashboard, continue straight into automation after watching.
                if section == .updates { setupAction = .automation }
                await load()
                releaseStatus = "\(section.rawValue) enabled."
            }.mobileSheetPresentation()
        }
        .task { await load() }
    }

    /// Repeated cursors are a loading failure, not evidence that setup is missing.
    private func validateNextPage(_ cursor: String?, visited: inout Set<String>) throws {
        try Task.checkCancellation()
        if let cursor, !visited.insert(cursor).inserted {
            throw FlowcyError.message("Could not finish loading repository settings. Please try again.")
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            switch section {
            case .docs:
                docs = nil
                var cursor: String?
                var visited = Set<String>()
                repeat {
                    let page = try await state.listDocsRepos(search: "", cursor: cursor)
                    docs = page.items.first { $0.id == project.id }
                    cursor = page.pagination?.hasMore == true ? page.pagination?.nextCursor : nil
                    if docs != nil { break }
                    try validateNextPage(cursor, visited: &visited)
                } while cursor != nil
            case .releases:
                release = nil
                releaseWorkflows = []
                var cursor: String?
                var visited = Set<String>()
                repeat {
                    let page = try await state.listReleaseRepos(cursor: cursor)
                    release = page.items.first { project.matchesRepository($0.repositoryFullName) }
                    cursor = page.pagination?.hasMore == true ? page.pagination?.nextCursor : nil
                    if release != nil { break }
                    try validateNextPage(cursor, visited: &visited)
                } while cursor != nil
                if isQuickAction, let release {
                    releaseWorkflows = MobileReleaseWorkflow.releaseOrder(
                        try await state.listReleaseWorkflows(repoId: release.id).filter(\.hasWorkflowDispatch))
                }
            case .updates:
                watched = nil
                ciOverview = nil
                guard let repository = project.repositoryFullName else { break }
                let overview = try await state.watchedRepoOverview(repository: repository)
                try Task.checkCancellation()
                ciOverview = overview
                watched = overview.repository
            default: break
            }
        } catch { self.error = error.localizedDescription }
    }
}
