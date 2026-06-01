import RxCodeCore
import SwiftUI

/// Detail for one watched repo, mirroring the github-pm webapp detail page:
/// header badges, an editable scan schedule, a "Trigger scan now" button, a
/// "Remove" button, and tabs for Scan History + Pull Requests.
struct CIUpdateRepoDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    let repo: WatchedRepo
    /// Called after the repo is removed, so the list can drop it and pop back.
    var onRemoved: ((WatchedRepo) -> Void)?
    /// Closes the enclosing manage sheet (kept available even when the deep link
    /// drills straight into this pushed view).
    var onClose: (() -> Void)?

    enum Tab: String, CaseIterable, Identifiable {
        case history = "Scan History"
        case prs = "Pull Requests"
        var id: String { rawValue }
    }

    @State private var frequency: CIScanFrequency
    @State private var selectedTab: Tab = .history
    @State private var history: [CIUpdateRunHistory] = []
    @State private var prs: [CIPullRequest] = []
    @State private var didLoadPRs = false
    @State private var isLoadingHistory = false
    @State private var isLoadingPRs = false
    @State private var isTriggering = false
    @State private var isUpdatingFrequency = false
    @State private var triggerMessage: String?
    @State private var lastTriggerPRURL: String?
    @State private var errorMessage: String?
    @State private var showRemoveConfirm = false
    @State private var closingPR: Int?

    init(repo: WatchedRepo, onRemoved: ((WatchedRepo) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.repo = repo
        self.onRemoved = onRemoved
        self.onClose = onClose
        _frequency = State(initialValue: repo.scanFrequency)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Group {
                switch selectedTab {
                case .history: historyList
                case .prs: prsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(repo.repo ?? repo.repositoryFullName)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
        .confirmationDialog(
            "Stop watching \(repo.repositoryFullName)?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Autopilot will no longer scan this repo or open CI update PRs.")
        }
        .task { await loadHistory() }
        .onChange(of: selectedTab) { _, tab in
            if tab == .prs, !didLoadPRs { Task { await loadPRs() } }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(ClaudeTheme.accent)
                Text(repo.repositoryFullName)
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                badge(
                    repo.scheduleId != nil ? "Auto · \(frequency.displayName)" : "Manual",
                    systemImage: repo.scheduleId != nil ? "clock.fill" : "hand.tap.fill"
                )
                if let date = repo.lastScannedDate {
                    badge("Last scan \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.seal.fill")
                } else {
                    badge("Never scanned", systemImage: "circle.dashed")
                }
            }

            HStack(spacing: 12) {
                Picker("Schedule", selection: $frequency) {
                    ForEach(CIScanFrequency.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 220)
                .disabled(isUpdatingFrequency)
                if isUpdatingFrequency { ProgressView().controlSize(.small) }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { await trigger() }
                } label: {
                    if isTriggering {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Trigger scan now", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTriggering)

                Button(role: .destructive) {
                    showRemoveConfirm = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }

            if let triggerMessage {
                HStack(spacing: 6) {
                    Text(triggerMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let urlString = lastTriggerPRURL, let url = URL(string: urlString) {
                        Button("Open PR") { openURL(url) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: frequency) { old, new in
            guard old != new else { return }
            Task { await updateFrequency(new) }
        }
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(NSColor.controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
    }

    // MARK: - Scan history

    @ViewBuilder
    private var historyList: some View {
        List {
            if history.isEmpty, !isLoadingHistory {
                Text("No scans yet. Trigger one to check this repo's actions.")
                    .foregroundStyle(.secondary)
            }
            ForEach(history) { run in
                CIScanRunRow(run: run) { url in openURL(url) }
            }
        }
        .overlay { if isLoadingHistory, history.isEmpty { ProgressView() } }
    }

    // MARK: - Pull requests

    @ViewBuilder
    private var prsList: some View {
        List {
            if prs.isEmpty, !isLoadingPRs {
                Text("No pull requests opened by autopilot yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(prs) { pr in
                CIPullRequestRow(
                    pr: pr,
                    isClosing: closingPR == pr.number,
                    onOpen: { url in openURL(url) },
                    onClose: { number in Task { await closePR(number) } }
                )
            }
        }
        .overlay { if isLoadingPRs, prs.isEmpty { ProgressView() } }
    }

    // MARK: - Actions

    private func loadHistory() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }
        do {
            history = try await appState.ciUpdates.history(id: repo.id, limit: 50)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPRs() async {
        isLoadingPRs = true
        defer { isLoadingPRs = false; didLoadPRs = true }
        do {
            prs = try await appState.ciUpdates.pullRequests(id: repo.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateFrequency(_ new: CIScanFrequency) async {
        isUpdatingFrequency = true
        errorMessage = nil
        defer { isUpdatingFrequency = false }
        do {
            try await appState.ciUpdates.updateScanFrequency(id: repo.id, frequency: new)
        } catch {
            errorMessage = error.localizedDescription
            frequency = repo.scanFrequency // revert the picker on failure
        }
    }

    private func trigger() async {
        isTriggering = true
        triggerMessage = nil
        lastTriggerPRURL = nil
        errorMessage = nil
        defer { isTriggering = false }
        do {
            let result = try await appState.ciUpdates.trigger(id: repo.id)
            if result.success {
                lastTriggerPRURL = result.prUrl
                triggerMessage = result.prUrl != nil ? "Scan complete — PR opened." : "Scan complete — everything up to date."
            } else {
                errorMessage = result.error ?? "Scan failed."
            }
            await loadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closePR(_ number: Int) async {
        closingPR = number
        errorMessage = nil
        defer { closingPR = nil }
        do {
            try await appState.ciUpdates.closePullRequest(id: repo.id, prNumber: number)
            prs.removeAll { $0.number == number }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        errorMessage = nil
        do {
            try await appState.ciUpdates.deleteWatchedRepository(id: repo.id)
            onRemoved?(repo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct CIScanRunRow: View {
    let run: CIUpdateRunHistory
    let onOpenPR: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: run.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(run.isSuccess ? Color.green : Color.red)
                Text(run.isSuccess ? "Success" : "Error")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                Spacer()
                if let date = run.startedDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if run.isSuccess {
                Text("\(run.workflowsScanned ?? 0) workflows · \(run.actionsFound ?? 0) actions · \(run.outdatedActionsCount ?? 0) outdated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let message = run.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if let urlString = run.prUrl, let url = URL(string: urlString) {
                Button {
                    onOpenPR(url)
                } label: {
                    Label(run.prNumber.map { "PR #\($0)" } ?? "View PR", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CIPullRequestRow: View {
    let pr: CIPullRequest
    let isClosing: Bool
    let onOpen: (URL) -> Void
    let onClose: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title ?? pr.number.map { "PR #\($0)" } ?? "Pull request")
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let number = pr.number { Text("#\(number)") }
                    if pr.merged == true {
                        Text("·"); Text("Merged")
                    } else if let state = pr.state {
                        Text("·"); Text(state.capitalized)
                    }
                    if let date = pr.createdDate {
                        Text("·"); Text(date.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let urlString = pr.htmlURL, let url = URL(string: urlString) {
                Button { onOpen(url) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open on GitHub")
            }
            if let number = pr.number, pr.isOpen {
                if isClosing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(role: .destructive) { onClose(number) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Close PR")
                }
            }
        }
        .padding(.vertical, 3)
    }
}
