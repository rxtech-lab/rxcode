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

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(repos) { repo in
                NavigationLink {
                    MobileCIRepoDetailView(repo: repo)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.fullName)
                        Text(repo.scanFrequency.displayName)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingDelete = repo }
                }
            }
            if repos.isEmpty, !isLoading {
                Text("No watched repositories. Tap + to add one.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("CI Auto-Update")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
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
        .alert(
            "Stop watching?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let repo = pendingDelete { Task { await delete(repo) } }
                pendingDelete = nil
            }
        }
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
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ repo: WatchedRepo) async {
        do {
            try await state.deleteWatchedRepo(id: repo.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileCIRepoDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    let repo: WatchedRepo

    @State private var frequency: CIScanFrequency
    @State private var history: [CIUpdateRunHistory] = []
    @State private var pullRequests: [CIPullRequest] = []
    @State private var isLoading = true
    @State private var isTriggering = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var pendingClose: CIPullRequest?

    init(repo: WatchedRepo) {
        self.repo = repo
        _frequency = State(initialValue: repo.scanFrequency)
    }

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
            }

            Section("Scan") {
                Picker("Frequency", selection: $frequency) {
                    ForEach(CIScanFrequency.allCases) { freq in
                        Text(freq.displayName).tag(freq)
                    }
                }
                .onChange(of: frequency) { _, value in
                    Task { await updateFrequency(value) }
                }
                Button {
                    Task { await trigger() }
                } label: {
                    if isTriggering {
                        HStack { ProgressView(); Text("Scanning…") }
                    } else {
                        Label("Trigger scan now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isTriggering)
            }

            Section("Scan History") {
                if history.isEmpty, !isLoading {
                    Text("No scans yet.").foregroundStyle(.secondary)
                }
                ForEach(history) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: run.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(run.isSuccess ? .green : .red)
                            Text(run.isSuccess ? "Success" : "Error")
                            Spacer()
                            if let date = run.startedDate {
                                Text(date, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let outdated = run.outdatedActionsCount {
                            Text("\(outdated) outdated action(s)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = run.errorMessage {
                            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                        if let url = run.prUrl, let link = URL(string: url) {
                            Link("View pull request", destination: link).font(.caption)
                        }
                    }
                }
            }

            Section("Pull Requests") {
                if pullRequests.isEmpty, !isLoading {
                    Text("No open auto-update pull requests.").foregroundStyle(.secondary)
                }
                ForEach(pullRequests) { pr in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(pr.title ?? "PR #\(pr.number ?? 0)")
                            Spacer()
                            if let url = pr.htmlURL, let link = URL(string: url) {
                                Link("Open", destination: link).font(.caption)
                            }
                        }
                        if let number = pr.number {
                            Text("#\(number)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Close", role: .destructive) { pendingClose = pr }
                    }
                }
            }
        }
        .navigationTitle(repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Close pull request?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Close PR", role: .destructive) {
                if let pr = pendingClose, let number = pr.number {
                    Task { await closePR(number) }
                }
                pendingClose = nil
            }
        }
        .mobileAutopilotLoadingOverlay(isLoading && history.isEmpty && pullRequests.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let h = state.watchedRepoHistory(id: repo.id, limit: 50)
            async let p = state.watchedRepoPullRequests(id: repo.id)
            history = try await h
            pullRequests = try await p
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateFrequency(_ value: CIScanFrequency) async {
        do {
            try await state.updateWatchedRepoFrequency(id: repo.id, frequency: value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trigger() async {
        isTriggering = true
        statusMessage = nil
        errorMessage = nil
        defer { isTriggering = false }
        do {
            let result = try await state.triggerWatchedRepoScan(id: repo.id)
            if result.success {
                statusMessage = result.prUrl != nil ? "Scan opened a pull request." : "Scan complete — no changes needed."
            } else {
                errorMessage = result.error ?? "Scan failed."
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closePR(_ number: Int) async {
        do {
            try await state.closeWatchedRepoPR(id: repo.id, prNumber: number)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
