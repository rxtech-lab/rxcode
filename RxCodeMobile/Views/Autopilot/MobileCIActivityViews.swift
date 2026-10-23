import Combine
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - CI history

struct MobileCIHistoryView: View {
    @EnvironmentObject private var state: MobileAppState
    @ObservedObject var model: MobileCIRepoModel

    var body: some View {
        List(model.history) { run in
            NavigationLink {
                MobileCIRunDetailView(run: run)
            } label: {
                MobileCIRunRow(run: run)
            }
        }
        .overlay {
            if model.history.isEmpty, !model.isLoading {
                ContentUnavailableView("No CI Scans Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Choose Scan CI Updates from the repository's actions menu to run the first scan."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("CI History")
        .refreshable { await model.reload(state) }
    }
}

private struct MobileCIRunRow: View {
    let run: CIUpdateRunHistory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: run.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(run.isSuccess ? .green : .red).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.isSuccess ? "Success" : "Error").font(.headline)
                if run.isSuccess {
                    Text("\(run.workflowsScanned ?? 0) workflows · \(run.actionsFound ?? 0) actions · \(run.outdatedActionsCount ?? 0) outdated")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let message = run.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                if let date = run.startedDate {
                    Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if run.prUrl != nil {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MobileCIRunDetailView: View {
    let run: CIUpdateRunHistory

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: run.isSuccess ? String(localized: "Success") : String(localized: "Error"))
                if let date = run.startedDate {
                    LabeledContent("Started", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let date = run.completedDate {
                    LabeledContent("Completed", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if run.isSuccess {
                Section("Results") {
                    LabeledContent("Workflows Scanned", value: "\(run.workflowsScanned ?? 0)")
                    LabeledContent("Actions Found", value: "\(run.actionsFound ?? 0)")
                    LabeledContent("Outdated Actions", value: "\(run.outdatedActionsCount ?? 0)")
                }
            }
            if let message = run.errorMessage {
                Section("Error") {
                    Text(message).font(.callout).textSelection(.enabled)
                }
            }
            if let raw = run.prUrl, let url = URL(string: raw) {
                Section("Pull Request") {
                    Link(destination: url) {
                        Label(run.prNumber.map { "Pull Request #\($0)" } ?? String(localized: "View Pull Request"),
                              systemImage: "arrow.up.right.square")
                    }
                    .simultaneousGesture(TapGesture().onEnded { MobileHaptics.buttonTap() })
                }
            }
        }
        .navigationTitle("CI Scan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Dependency & security scans

struct MobileDependencyRunsView: View {
    @EnvironmentObject private var state: MobileAppState
    @ObservedObject var model: MobileCIRepoModel

    private var runs: [DependencyUpdateRun] { model.automation?.runs ?? [] }

    var body: some View {
        List(runs) { run in
            NavigationLink {
                MobileDependencyRunDetailView(model: model, runID: run.id)
            } label: {
                MobileDependencyRunRow(run: run)
            }
        }
        .overlay {
            if let error = model.automationError, runs.isEmpty {
                ContentUnavailableView("Scans Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runs.isEmpty, !model.isLoading {
                ContentUnavailableView("No Dependency or Security Scans", systemImage: "shippingbox",
                                       description: Text("Turn on dependency updates in automation settings, then choose Scan Dependencies from the actions menu."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Dependencies & Security")
        .refreshable { await model.reloadAutomation(state) }
    }
}

private struct MobileDependencyRunStatus {
    let run: DependencyUpdateRun
    var title: LocalizedStringKey {
        switch run.status {
        case "queued": "Queued"
        case "running": "Running"
        case "success": "Completed"
        default: "Needs Attention"
        }
    }
    var icon: String {
        switch run.status {
        case "queued": "clock"
        case "running": "arrow.triangle.2.circlepath"
        case "success": "checkmark.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch run.status {
        case "queued", "running": .orange
        case "success": .green
        default: .red
        }
    }
}

private struct MobileDependencyRunRow: View {
    let run: DependencyUpdateRun

    var body: some View {
        let status = MobileDependencyRunStatus(run: run)
        HStack(alignment: .top, spacing: 12) {
            if run.isActive {
                ProgressView().frame(width: 24)
            } else {
                Image(systemName: status.icon).foregroundStyle(status.color).font(.title3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(run.isDependencies ? "Dependencies" : "CI Security").font(.headline)
                HStack(spacing: 4) {
                    Text(status.title)
                    if let count = run.findings?.count, count > 0 { Text("· \(count) vulnerabilities") }
                    if let count = run.prUrls?.count, count > 0 { Text("· \(count) PRs") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let date = run.startedDate {
                    Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MobileDependencyRunDetailView: View {
    @ObservedObject var model: MobileCIRepoModel
    let runID: String

    var body: some View {
        if let run = model.automation?.runs.first(where: { $0.id == runID }) {
            let status = MobileDependencyRunStatus(run: run)
            List {
                Section {
                    LabeledContent("Scan", value: run.isDependencies ? String(localized: "Dependencies") : String(localized: "CI Security"))
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if run.isActive { ProgressView().controlSize(.small) }
                            Text(status.title).foregroundStyle(status.color)
                        }
                    }
                    if let date = run.startedDate {
                        LabeledContent("Started", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let date = run.completedDate {
                        LabeledContent("Completed", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let message = run.error, !message.isEmpty {
                    Section("Details") { Text(message).font(.callout).textSelection(.enabled) }
                }
                if let urls = run.prUrls, !urls.isEmpty {
                    Section("Pull Requests") {
                        ForEach(urls, id: \.self) { raw in
                            if let url = URL(string: raw) {
                                Link(destination: url) {
                                    Label(Int(url.lastPathComponent).map { String(localized: "Pull Request #\($0)") } ?? raw,
                                          systemImage: "arrow.triangle.pull")
                                }
                            }
                        }
                    }
                }
                if let findings = run.findings, !findings.isEmpty {
                    Section("Vulnerabilities (\(findings.count))") {
                        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                            NavigationLink {
                                MobileVulnerabilityDetailView(finding: finding)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(finding.id).font(.headline.monospaced())
                                    Text("\(finding.package)@\(finding.version)").font(.caption)
                                    Text(finding.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(run.isDependencies ? "Dependency Scan" : "CI Security Scan")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Scan Unavailable", systemImage: "shippingbox")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MobileVulnerabilityDetailView: View {
    @Environment(\.openURL) private var openURL
    let finding: DependencyVulnerability

    var body: some View {
        List {
            Section {
                LabeledContent("Advisory", value: finding.id)
                LabeledContent("Package", value: finding.package)
                LabeledContent("Version", value: finding.version.isEmpty ? "—" : finding.version)
            }
            Section("Location") {
                Text(finding.path).font(.callout.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle(finding.id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = URL(string: finding.url) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open Advisory", systemImage: "safari") {
                        MobileHaptics.buttonTap()
                        openURL(url)
                    }
                }
            }
        }
    }
}

// MARK: - CI pull requests

struct MobileCIPullRequestsView: View {
    @EnvironmentObject private var state: MobileAppState
    @ObservedObject var model: MobileCIRepoModel

    var body: some View {
        List(model.pullRequests) { pr in
            NavigationLink {
                MobileCIPullRequestDetailView(model: model, pr: pr)
            } label: {
                MobileCIPullRequestRow(pr: pr)
            }
        }
        .overlay {
            if model.pullRequests.isEmpty, !model.isLoading {
                ContentUnavailableView("No CI Update Pull Requests", systemImage: "arrow.triangle.pull",
                                       description: Text("Pull requests opened by CI update scans appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("CI Pull Requests")
        .refreshable { await model.reloadPullRequests(state) }
    }
}

private struct MobileCIPullRequestAppearance {
    let pr: CIPullRequest
    var label: LocalizedStringKey { pr.merged == true ? "Merged" : pr.isOpen ? "Open" : "Closed" }
    var color: Color { pr.merged == true ? .purple : pr.isOpen ? .green : .red }
    var icon: String { pr.merged == true ? "arrow.triangle.merge" : "arrow.triangle.pull" }
}

private struct MobileCIPullRequestRow: View {
    let pr: CIPullRequest

    var body: some View {
        let look = MobileCIPullRequestAppearance(pr: pr)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: look.icon).foregroundStyle(look.color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title ?? "PR #\(pr.number ?? 0)").font(.headline).lineLimit(2)
                HStack(spacing: 4) {
                    if let number = pr.number { Text("#\(number) ·") }
                    Text(look.label)
                    if let date = pr.createdDate { Text("· \(date, format: .relative(presentation: .named))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MobileCIPullRequestDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: MobileCIRepoModel
    let pr: CIPullRequest

    @State private var confirmClose = false
    @State private var closing = false
    @State private var errorMessage: String?

    private var url: URL? { pr.htmlURL.flatMap(URL.init(string:)) }

    var body: some View {
        let look = MobileCIPullRequestAppearance(pr: pr)
        List {
            Section {
                Text(pr.title ?? "PR #\(pr.number ?? 0)").font(.headline)
                LabeledContent("State") { Label(look.label, systemImage: look.icon).foregroundStyle(look.color) }
                if let number = pr.number { LabeledContent("Number", value: "#\(number)") }
                if let date = pr.createdDate {
                    LabeledContent("Opened", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .navigationTitle(pr.number.map { "#\($0)" } ?? String(localized: "Pull Request"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url {
                        Button("Open in GitHub", systemImage: "safari") { MobileHaptics.buttonTap(); openURL(url) }
                        ShareLink(item: url)
                    }
                    if pr.isOpen, pr.merged != true, pr.number != nil {
                        Section {
                            Button("Close Pull Request", systemImage: "xmark.circle", role: .destructive) {
                                MobileHaptics.buttonTap()
                                confirmClose = true
                            }
                        }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(closing)
            }
        }
        .confirmationDialog("Close pull request #\(pr.number ?? 0)?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Pull Request", role: .destructive) { Task { await close() } }
        } message: {
            Text("The pull request is closed on GitHub without merging.")
        }
        .alert("Could Not Close Pull Request", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .mobileAutopilotLoadingDialog(closing, title: "Closing pull request…")
    }

    private func close() async {
        guard let number = pr.number else { return }
        closing = true
        defer { closing = false }
        do {
            try await state.closeWatchedRepoPR(id: model.repo.id, prNumber: number)
            MobileHaptics.connected()
            await model.reloadPullRequests(state)
            dismiss()
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }
}
