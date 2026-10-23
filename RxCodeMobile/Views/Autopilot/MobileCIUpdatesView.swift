import Combine
import RxCodeCore
import RxCodeSync
import SwiftUI

/// CI auto-update: watched repositories and their scan schedule, history, and
/// auto-update pull requests.
struct MobileCIUpdatesView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var repos: [WatchedRepo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var pendingDelete: WatchedRepo?
    @State private var isRemoving = false

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(repos) { repo in
                NavigationLink {
                    MobileCIRepoDetailView(repo: repo, onRemoved: { await reload() })
                } label: {
                    MobileWatchedRepoRow(repo: repo)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingDelete = repo }
                }
                .contextMenu {
                    Button("Remove from Watch List", systemImage: "trash", role: .destructive) { pendingDelete = repo }
                }
            }
        }
        .overlay {
            if repos.isEmpty, !isLoading, errorMessage == nil {
                ContentUnavailableView {
                    Label("No Watched Repositories", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("Watch a repository to keep its GitHub Actions and dependencies up to date.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("CI Auto-Update")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Watch Repository", systemImage: "plus") {
                    MobileHaptics.buttonTap()
                    showingAdd = true
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            MobileAutopilotRepoPicker(
                title: "Watch Repository",
                existingRepoFullNames: Set(repos.map { $0.fullName.lowercased() })
            ) { repo in
                await add(repo)
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .confirmationDialog(
            "Stop watching \(pendingDelete?.fullName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove from Watch List", role: .destructive) {
                if let repo = pendingDelete { Task { await delete(repo) } }
                pendingDelete = nil
            }
        } message: {
            Text("Automatic scans stop. Existing pull requests stay open.")
        }
        .mobileAutopilotLoadingDialog(isRemoving, title: "Removing repository…")
        .mobileAutopilotLoadingOverlay(isLoading && repos.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            repos = try await state.listWatchedRepos().repositories
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ repo: SecretsManagedRepo) async {
        do {
            try await state.addWatchedRepo(AddWatchedRepoBody(
                installationId: repo.installationId,
                repositoryId: repo.id,
                repositoryFullName: repo.fullName,
                scanFrequency: .weekly
            ))
            MobileHaptics.connected()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }

    private func delete(_ repo: WatchedRepo) async {
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await state.deleteWatchedRepo(id: repo.id)
            MobileHaptics.connected()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}

private struct MobileWatchedRepoRow: View {
    let repo: WatchedRepo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repo.fullName).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(repo.scheduleId == nil ? "Manual" : "Auto: \(repo.scanFrequency.displayName)")
                Text("·")
                if let date = repo.lastScannedDate {
                    Text("Scanned \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Never scanned")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Repository model

/// Shared state for one watched repository so pushed screens (history, scans,
/// pull requests) stay live while the detail screen polls queued scans.
@MainActor
final class MobileCIRepoModel: ObservableObject {
    @Published private(set) var repo: WatchedRepo
    @Published private(set) var automation: RepositoryAutomationResponse?
    @Published private(set) var history: [CIUpdateRunHistory] = []
    @Published private(set) var pullRequests: [CIPullRequest] = []
    @Published private(set) var isLoading = false
    @Published var loadError: String?
    @Published private(set) var automationError: String?

    private(set) var hasLoaded = false

    init(repo: WatchedRepo, overview: CIRepositoryOverview? = nil) {
        self.repo = repo
        if let overview { apply(overview) }
    }

    private func apply(_ overview: CIRepositoryOverview) {
        if let repository = overview.repository { repo = repository }
        if let history = overview.history { self.history = history }
        if let pullRequests = overview.pullRequests { self.pullRequests = pullRequests }
        automation = overview.automation
        automationError = overview.errors["automation"]
        loadError = overview.errors["history"] ?? overview.errors["pullRequests"]
        hasLoaded = true
    }

    var hasActiveScans: Bool { automation?.runs.contains { $0.isActive } ?? false }
    var dependencyScanAvailable: Bool {
        automation.map { $0.settings.dependenciesEnabled && $0.scannerConfigured } ?? false
    }

    func reload(_ state: MobileAppState) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let overview = try await state.watchedRepoOverview(repository: repo.fullName)
            guard overview.repository != nil else {
                loadError = String(localized: "Repository is no longer configured for CI updates.")
                return
            }
            apply(overview)
        } catch { loadError = error.localizedDescription }
    }

    func reloadAutomation(_ state: MobileAppState) async {
        do {
            automation = try await state.watchedRepoAutomation(id: repo.id)
            automationError = nil
        } catch { automationError = automationFailure(error) }
    }

    private func automationFailure(_ error: Error) -> String {
        if case CIUpdateService.ServiceError.apiError(404, let detail) = error, detail.isEmpty {
            return String(localized: "Automation is unavailable on this Flowcy server. Update the service, then try again. CI history and pull requests remain available.")
        }
        return error.localizedDescription
    }

    func reloadPullRequests(_ state: MobileAppState) async {
        if let value = try? await state.watchedRepoPullRequests(id: repo.id) { pullRequests = value }
    }

    /// Schedule and last-scan metadata only come from the list endpoint.
    func refreshRepo(_ state: MobileAppState) async {
        var cursor: String?
        var visited = Set<String>()
        repeat {
            guard let page = try? await state.listWatchedRepos(cursor: cursor) else { return }
            if let match = page.repositories.first(where: { $0.id == repo.id }) {
                repo = match
                return
            }
            cursor = page.hasMore ? page.nextCursor : nil
            if let cursor, !visited.insert(cursor).inserted { return }
        } while cursor != nil
    }

    func didSave(_ settings: RepositoryAutomationSettings) {
        guard let automation else { return }
        self.automation = RepositoryAutomationResponse(settings: settings, runs: automation.runs,
                                                       scannerConfigured: automation.scannerConfigured)
    }
}

/// Entry actions a caller can request when opening a repository, e.g. from the
/// project quick-action menu or right after watching a repository.
enum MobileCIRepoAction: String, Identifiable {
    case scanCI, scanDependencies, automation
    var id: Self { self }
}

// MARK: - Repository detail

struct MobileCIRepoDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model: MobileCIRepoModel
    private let onRemoved: (() async -> Void)?
    @State private var pendingAction: MobileCIRepoAction?

    @State private var confirmCIScan = false
    @State private var confirmDependencyScan = false
    @State private var confirmRemove = false
    @State private var dependencyBlocker: String?
    @State private var showingAutomation = false
    @State private var busyTitle: LocalizedStringKey?
    @State private var ciResult: CITriggerResponse?
    @State private var errorMessage: String?
    @State private var toast: String?

    init(repo: WatchedRepo, overview: CIRepositoryOverview? = nil, initialAction: MobileCIRepoAction? = nil, onRemoved: (() async -> Void)? = nil) {
        _model = StateObject(wrappedValue: MobileCIRepoModel(repo: repo, overview: overview))
        _pendingAction = State(initialValue: initialAction)
        self.onRemoved = onRemoved
    }

    private var repo: WatchedRepo { model.repo }

    var body: some View {
        List {
            Section {
                LabeledContent("Schedule", value: repo.scheduleId == nil
                               ? String(localized: "Manual")
                               : String(localized: "Auto · \(repo.scanFrequency.displayName)"))
                LabeledContent("Last Scanned") {
                    if let date = repo.lastScannedDate {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Never")
                    }
                }
                if let added = repo.createdDate {
                    LabeledContent("Added", value: added.formatted(date: .abbreviated, time: .omitted))
                }
            } header: {
                Text(repo.fullName)
            }

            Section("Activity") {
                NavigationLink {
                    MobileCIHistoryView(model: model)
                } label: {
                    MobileCIActivityRow(title: "CI History", systemImage: "clock.arrow.circlepath",
                                        detail: model.history.first.map { $0.isSuccess ? "Success" : "Error" },
                                        count: model.history.count)
                }
                NavigationLink {
                    MobileDependencyRunsView(model: model)
                } label: {
                    MobileCIActivityRow(title: "Dependencies & Security", systemImage: "shippingbox",
                                        detail: model.hasActiveScans ? "Scanning…" : nil,
                                        count: model.automation?.runs.count ?? 0,
                                        isActive: model.hasActiveScans)
                }
                NavigationLink {
                    MobileCIPullRequestsView(model: model)
                } label: {
                    MobileCIActivityRow(title: "CI Pull Requests", systemImage: "arrow.triangle.pull",
                                        detail: nil, count: model.pullRequests.filter(\.isOpen).count)
                }
            }

            Section {
                NavigationLink {
                    MobileAutomationSummaryView(model: model) { showingAutomation = true }
                } label: {
                    LabeledContent {
                        Text(automationSummary).foregroundStyle(.secondary)
                    } label: {
                        Label("Automation", systemImage: "wand.and.stars")
                    }
                }
            } footer: {
                if let error = model.automationError {
                    Text(error)
                } else if let automation = model.automation, !automation.scannerConfigured {
                    Text("The dependency scanner needs deployment configuration before scans can run.")
                }
            }
        }
        .navigationTitle(repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .confirmationDialog("Scan CI updates?", isPresented: $confirmCIScan, titleVisibility: .visible) {
            Button("Scan CI Updates") { Task { await runCIScan() } }
        } message: {
            Text("Checks \(repo.fullName)'s GitHub Actions for outdated versions and opens a pull request when updates are needed.")
        }
        .confirmationDialog("Scan dependencies?", isPresented: $confirmDependencyScan, titleVisibility: .visible) {
            Button("Queue Dependency Scan") { Task { await runDependencyScan() } }
        } message: {
            Text("The scan runs in the background. Results appear in Dependencies & Security.")
        }
        .confirmationDialog("Stop watching \(repo.fullName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from Watch List", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Removes the repository and its automatic scan schedule.")
        }
        .alert("Dependency Scan Unavailable", isPresented: Binding(get: { dependencyBlocker != nil }, set: { if !$0 { dependencyBlocker = nil } })) {
            if model.automation?.settings.dependenciesEnabled == false {
                Button("Automation Settings") { showingAutomation = true }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(dependencyBlocker ?? "") }
        .alert(ciResult?.prUrl == nil ? "CI Scan Complete" : "Pull Request Created",
               isPresented: Binding(get: { ciResult != nil }, set: { if !$0 { ciResult = nil } })) {
            if let raw = ciResult?.prUrl, let url = URL(string: raw) {
                Button("View Pull Request") { MobileHaptics.buttonTap(); openURL(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(ciResult?.prUrl == nil
                 ? "All GitHub Actions are up to date. No changes were needed."
                 : "A pull request with the GitHub Actions updates is ready for review.")
        }
        .alert("Could Not Complete Request", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showingAutomation) {
            MobileAutomationSettingsSheet(model: model) { message in show(message) }
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .mobileAutopilotLoadingDialog(busyTitle != nil, title: busyTitle ?? "Working…")
        .mobileAutopilotLoadingOverlay(model.isLoading && model.automation == nil && model.history.isEmpty)
        .mobileStatusToast($toast)
        .refreshable { await model.reload(state) }
        .task {
            if !model.hasLoaded { await model.reload(state) }
            if let message = model.loadError { errorMessage = message }
            if let action = pendingAction {
                pendingAction = nil
                perform(action)
            }
        }
        .task(id: model.hasActiveScans) {
            // Match the dashboard: refresh scan progress every 10s while a scan is queued or running.
            while model.hasActiveScans, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await model.reloadAutomation(state)
                if !model.hasActiveScans {
                    MobileHaptics.streamFinished()
                    show(String(localized: "Dependency scan finished."))
                    await model.reloadPullRequests(state)
                }
            }
        }
    }

    private var automationSummary: String {
        guard let settings = model.automation?.settings else { return "" }
        var parts: [String] = []
        if settings.dependenciesEnabled { parts.append(String(localized: "Updates")) }
        if settings.dependencySecurityEnabled || settings.ciSecurityEnabled { parts.append(String(localized: "Security")) }
        if settings.dependencyAutoMerge || settings.ciAutoMerge { parts.append(String(localized: "Auto-merge")) }
        return parts.isEmpty ? String(localized: "Off") : parts.joined(separator: ", ")
    }

    @ToolbarContentBuilder private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Scan") {
                    Button("Scan CI Updates", systemImage: "arrow.triangle.2.circlepath") { perform(.scanCI) }
                    Button("Scan Dependencies", systemImage: "shippingbox") { perform(.scanDependencies) }
                }
                Section {
                    Button("Automation Settings", systemImage: "wand.and.stars") { perform(.automation) }
                        .disabled(model.automation == nil)
                }
                Section {
                    Button("Remove from Watch List", systemImage: "trash", role: .destructive) {
                        MobileHaptics.buttonTap()
                        confirmRemove = true
                    }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .disabled(busyTitle != nil)
        }
    }

    private func perform(_ action: MobileCIRepoAction) {
        MobileHaptics.buttonTap()
        switch action {
        case .scanCI:
            confirmCIScan = true
        case .scanDependencies:
            // Mirrors the dashboard, which only enables the scan once it can run.
            guard let automation = model.automation else {
                dependencyBlocker = model.automationError ?? String(localized: "Automation settings are still loading. Try again in a moment.")
                return
            }
            if !automation.settings.dependenciesEnabled {
                dependencyBlocker = String(localized: "Turn on “Automatically update dependencies” in automation settings first.")
            } else if !automation.scannerConfigured {
                dependencyBlocker = String(localized: "The dependency scanner is not configured on this deployment.")
            } else if model.hasActiveScans {
                dependencyBlocker = String(localized: "A scan is already in progress. Results will appear when it finishes.")
            } else {
                confirmDependencyScan = true
            }
        case .automation:
            if model.automation != nil { showingAutomation = true }
        }
    }

    private func runCIScan() async {
        busyTitle = "Scanning CI updates…"
        defer { busyTitle = nil }
        do {
            let response = try await state.triggerWatchedRepoScan(id: repo.id)
            guard response.success else { throw FlowcyError.message(response.error ?? String(localized: "CI scan failed.")) }
            MobileHaptics.connected()
            await model.reload(state)
            ciResult = response
        } catch {
            MobileHaptics.connectionError()
            // A failed scan is still recorded in history on the server.
            await model.reload(state)
            errorMessage = error.localizedDescription
        }
    }

    private func runDependencyScan() async {
        busyTitle = "Queuing dependency scan…"
        defer { busyTitle = nil }
        do {
            let response = try await state.triggerWatchedRepoDependencyScan(id: repo.id)
            guard response.queued else { throw FlowcyError.message(String(localized: "Dependency scan was not queued.")) }
            MobileHaptics.connected()
            await model.reloadAutomation(state)
            show(String(localized: "Dependency scan queued."))
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        busyTitle = "Removing repository…"
        defer { busyTitle = nil }
        do {
            try await state.deleteWatchedRepo(id: repo.id)
            MobileHaptics.connected()
            if let onRemoved { await onRemoved() }
            dismiss()
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
    }
}

private struct MobileCIActivityRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: LocalizedStringKey?
    let count: Int
    var isActive = false

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if isActive { ProgressView().controlSize(.small) }
            if let detail { Text(detail).foregroundStyle(.secondary) }
            if count > 0 {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

// MARK: - Toast (shared by Flowcy repository screens)

struct MobileStatusToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation { self.message = nil } }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { self.message = nil }
                    }
            }
        }
    }
}

extension View {
    func mobileStatusToast(_ message: Binding<String?>) -> some View {
        modifier(MobileStatusToastModifier(message: message))
    }
}
