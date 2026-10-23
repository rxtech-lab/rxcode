import RxCodeCore
import SwiftUI

struct FlowcyCIRun: Decodable, Identifiable {
    let id: Int
    let name: String?
    let display_title: String?
    let run_number: Int
    let status: String?
    let conclusion: String?
    let head_branch: String?
    let html_url: String?
    let created_at: String?
}

struct FlowcyCIJob: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let steps: [Step]?

    struct Step: Decodable, Identifiable {
        let number: Int
        let name: String
        let status: String?
        let conclusion: String?
        var id: Int { number }
    }
}

private struct CIRunsResponse: Decodable {
    let runs: [FlowcyCIRun]
    let hasMore: Bool
}
private struct CIJobsResponse: Decodable { let jobs: [FlowcyCIJob] }
private struct CILogsResponse: Decodable { let logs: String }

struct FlowcyCIRunsView: View {
    let repository: String
    let workflow: CIWorkflowStatus?
    @State private var runs: [FlowcyCIRun] = []
    @State private var loading = false
    @State private var error: String?
    @State private var page = 0
    @State private var hasMore = false

    var body: some View {
        List {
            ForEach(runs) { run in
                NavigationLink {
                    FlowcyCIRunDetailView(repository: repository, run: run)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.display_title ?? run.name ?? "Workflow Run").font(.headline)
                        CIExecutionStatus(status: run.status, conclusion: run.conclusion)
                        Text(["#\(run.run_number)", run.head_branch].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let date = FlowcyCIStatusView.date(run.created_at) {
                            Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                .simultaneousGesture(TapGesture().onEnded { MobileHaptics.buttonTap() })
            }
            if let error, !runs.isEmpty {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load(reset: false) } }
                }
            } else if hasMore {
                Button("Load More") { Task { await load(reset: false) } }.disabled(loading)
            }
            if loading && !runs.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
        .overlay {
            if runs.isEmpty {
                CIContentState(loading: loading, error: error, title: "No Recent Runs") {
                    Task { await load(reset: true) }
                }
            }
        }
        .navigationTitle(workflow?.workflowName ?? "Recent Runs")
        .refreshable { await load(reset: true) }
        .task { if runs.isEmpty { await load(reset: true) } }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let nextPage = reset ? 1 : page + 1
            var parameters = ["page": String(nextPage)]
            if let id = workflow?.workflowId { parameters["workflowId"] = String(id) }
            let response: CIRunsResponse = try await AutopilotService(rxAuth: .shared)
                .ciActivity(repository: repository, parameters: parameters)
            try Task.checkCancellation()
            let existing = reset ? [] : runs
            let ids = Set(existing.map(\.id))
            runs = existing + response.runs.filter { !ids.contains($0.id) }
            page = nextPage
            hasMore = response.hasMore
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}

private struct FlowcyCIRunDetailView: View {
    let repository: String
    let run: FlowcyCIRun
    @State private var jobs: [FlowcyCIJob] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedJob: FlowcyCIJob?

    var body: some View {
        List {
            Section {
                Text(run.display_title ?? run.name ?? "Workflow Run").font(.headline)
                CIExecutionStatus(status: run.status, conclusion: run.conclusion)
                if let url = FlowcyCIStatusView.githubURL(run.html_url) {
                    Link(destination: url) { Label("Open in GitHub", systemImage: "arrow.up.right.square") }
                }
            }
            ForEach(jobs) { job in
                Section {
                    CIExecutionStatus(status: job.status, conclusion: job.conclusion)
                    ForEach(job.steps ?? []) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.name)
                            CIExecutionStatus(status: step.status, conclusion: step.conclusion).font(.caption)
                        }
                    }
                    Button {
                        MobileHaptics.buttonTap()
                        selectedJob = job
                    } label: { Label("View Log", systemImage: "doc.text.magnifyingglass") }
                } header: { Text(job.name) }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            } else if !loading && jobs.isEmpty {
                Text("No jobs are available yet. Pull to refresh.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Run #\(run.run_number)")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selectedJob) { job in
            NavigationStack { FlowcyCIJobLogView(repository: repository, job: job) }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: CIJobsResponse = try await AutopilotService(rxAuth: .shared)
                .ciActivity(repository: repository, parameters: ["runId": String(run.id)])
            try Task.checkCancellation()
            jobs = response.jobs
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}

private struct FlowcyCIJobLogView: View {
    @Environment(\.dismiss) private var dismiss
    let repository: String
    let job: FlowcyCIJob
    @State private var logs: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let logs, !logs.isEmpty {
                // Logs are verbatim terminal output, never interpreted as Markdown.
                ScrollView([.horizontal, .vertical]) {
                    Text(logs).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding()
                }
            } else {
                CIContentState(loading: loading, error: error, title: "Log Not Available Yet") {
                    Task { await load() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .overlay { if loading && logs != nil { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("Unable to Load Log", isPresented: Binding(get: { error != nil && logs != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .task { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: CILogsResponse = try await AutopilotService(rxAuth: .shared)
                .ciActivity(repository: repository, parameters: ["jobId": String(job.id)])
            try Task.checkCancellation()
            logs = response.logs
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}

private struct CIContentState: View {
    let loading: Bool
    let error: String?
    let title: String
    let retry: () -> Void
    var body: some View {
        Group {
            if loading { ProgressView("Loading…") }
            else {
                ContentUnavailableView {
                    Label(error == nil ? title : "Unable to Load CI", systemImage: error == nil ? "gearshape.2" : "exclamationmark.triangle")
                } description: {
                    if let error { Text(error) }
                } actions: { Button("Refresh", action: retry) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CIExecutionStatus: View {
    let status: String?
    let conclusion: String?
    private var value: String { conclusion ?? status ?? "unknown" }
    private var color: Color {
        switch value {
        case "success": .green
        case "failure", "timed_out", "action_required": .red
        case "queued", "in_progress", "waiting", "pending": .orange
        default: .secondary
        }
    }
    var body: some View {
        Label(value.replacingOccurrences(of: "_", with: " ").capitalized,
              systemImage: value == "success" ? "checkmark.circle.fill" : value == "failure" ? "xmark.circle.fill" : "circle.fill")
            .foregroundStyle(color)
    }
}
