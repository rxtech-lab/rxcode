import RxCodeCore
import SwiftUI

/// Project CI tab. Mirrors the web dashboard's workflow list using the bearer-authenticated
/// `POST /api/v1/ci-status/batch`, which reports the latest run of each workflow.
struct FlowcyCIStatusView: View {
    @Environment(\.openURL) private var openURL
    let repositoryFullName: String

    @State private var status: ProjectCIStatus?
    @State private var loading = false
    @State private var error: String?

    private var workflows: [CIWorkflowStatus] {
        (status?.workflows ?? []).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    var body: some View {
        Group {
            if let status, status.found, !status.workflows.isEmpty {
                List {
                    Section { summary(status) }
                    Section {
                        NavigationLink("Recent Runs") {
                            FlowcyCIRunsView(repository: repositoryFullName, workflow: nil)
                        }
                    }
                    Section("Workflows") {
                        ForEach(Array(workflows.enumerated()), id: \.offset) { _, workflow in
                            NavigationLink {
                                FlowcyCIRunsView(repository: repositoryFullName, workflow: workflow)
                            } label: {
                                FlowcyCIWorkflowRow(workflow: workflow)
                            }
                        }
                    }
                }
                .refreshable { await load() }
            } else if loading {
                ProgressView("Loading CI…")
            } else if let error {
                ContentUnavailableView {
                    Label("Unable to Load CI", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ContentUnavailableView {
                    Label("No CI Activity", systemImage: "gearshape.2")
                } description: {
                    Text("No workflow runs have been recorded for this repository. Flowcy records activity when its GitHub App receives workflow run events.")
                } actions: {
                    Button("Refresh") { Task { await load() } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("CI")
        .toolbar {
            if workflows.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        FlowcyCIRunsView(repository: repositoryFullName, workflow: nil)
                    } label: { Label("Recent Runs", systemImage: "clock.arrow.circlepath") }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder private func summary(_ status: ProjectCIStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.overallIcon(status.overallState))
                .font(.title2)
                .foregroundStyle(Self.overallColor(status.overallState))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.overallTitle(status.overallState)).font(.headline)
                Text([status.branch, status.headSha.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let date = Self.date(status.lastUpdated) {
                    Text("Updated \(date, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        if let number = status.prNumber {
            Button {
                open(status.prUrl ?? "https://github.com/\(repositoryFullName)/pull/\(number)")
            } label: {
                Label("Pull Request #\(number)\(status.prState.map { " · \($0.capitalized)" } ?? "")",
                      systemImage: "arrow.triangle.pull")
            }
        }
    }

    private func open(_ raw: String?) {
        guard let url = Self.githubURL(raw) else { return }
        MobileHaptics.buttonTap()
        openURL(url)
    }

    private func load() async {
        guard !loading else { return }
        let parts = repositoryFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            error = String(localized: "This project is not linked to a GitHub repository.")
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response = try await AutopilotService(rxAuth: .shared)
                .batchCIStatus([CIStatusQuery(owner: parts[0], repo: parts[1], branch: nil)])
            try Task.checkCancellation()
            status = response.results.first
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }

    static func githubURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func overallTitle(_ state: CIOverallState) -> String {
        switch state {
        case .success: String(localized: "All workflows passing")
        case .failure: String(localized: "Some workflows failing")
        case .pending: String(localized: "Workflows running")
        case .unknown: String(localized: "Status unknown")
        }
    }

    private static func overallIcon(_ state: CIOverallState) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private static func overallColor(_ state: CIOverallState) -> Color {
        switch state {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case .unknown: .secondary
        }
    }
}

private struct FlowcyCIWorkflowRow: View {
    let workflow: CIWorkflowStatus

    /// Same status/conclusion mapping as the web workflow list.
    private var appearance: (icon: String, color: Color, label: String) {
        if workflow.status != "completed" {
            return ("clock.fill", .orange, (workflow.status ?? "queued").replacingOccurrences(of: "_", with: " ").capitalized)
        }
        switch workflow.conclusion {
        case "success": return ("checkmark.circle.fill", .green, String(localized: "Success"))
        case "failure", "timed_out", "action_required":
            return ("xmark.circle.fill", .red, (workflow.conclusion ?? "").replacingOccurrences(of: "_", with: " ").capitalized)
        case "cancelled": return ("slash.circle", .secondary, String(localized: "Cancelled"))
        case "skipped": return ("forward.circle", .secondary, String(localized: "Skipped"))
        default: return ("circle", .secondary, (workflow.conclusion ?? "Completed").capitalized)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: appearance.icon).font(.title3).foregroundStyle(appearance.color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(workflow.workflowName ?? String(localized: "Unknown Workflow")).font(.headline).lineLimit(2)
                Text([appearance.label, workflow.runNumber.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let date = FlowcyCIStatusView.date(workflow.updatedAt) {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}
