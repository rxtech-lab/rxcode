import Foundation

public actor GitHubCIUsagePlugin: UsagePlugin {
    public nonisolated let descriptor = UsagePluginDescriptor(id: "github-ci", title: "GitHub CI", authentication: "API key", resourceLabel: "Repository (owner/name)")
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func fetch(configuration c: UsageIntegration, credential: String, now: Date) async throws -> UsagePluginSnapshot {
        let repos = c.account.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !credential.isEmpty, !repos.isEmpty, repos.count <= 30 else { throw UsagePluginError.invalidConfiguration }
        var samples: [CIWaitSample] = []
        let from = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 86400))
        for repo in Set(repos).sorted() {
            let components = repo.split(separator: "/")
            guard components.count == 2, components.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { throw UsagePluginError.invalidConfiguration }
            for page in 1...10 {
                var url = URLComponents(string: "https://api.github.com/repos/\(repo)/actions/runs")!
                url.queryItems = [URLQueryItem(name: "event", value: "pull_request"), URLQueryItem(name: "per_page", value: "100"),
                                  URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "created", value: ">=\(from)")]
                var request = URLRequest(url: url.url!)
                request.timeoutInterval = 45
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
                guard response.statusCode == 200 else { throw UsagePluginError.http(response.statusCode) }
                let envelope = try JSONDecoder().decode(Runs.self, from: data)
                for run in envelope.workflow_runs {
                    // Reruns retain the original created_at; exclude them so
                    // that elapsed time since the original run is not queue time.
                    guard run.run_attempt == 1, let started = run.run_started_at,
                          let created = ISO8601DateFormatter().date(from: run.created_at),
                          let start = ISO8601DateFormatter().date(from: started), start >= created else { continue }
                    for pr in run.pull_requests {
                        samples.append(.init(id: "\(repo):\(run.id):\(pr.number)", repository: repo, pr: pr.number, seconds: start.timeIntervalSince(created)))
                    }
                }
                if envelope.workflow_runs.count < 100 { break }
                if page == 10 { throw UsagePluginError.paginationLimit }
            }
        }
        return .init(id: c.id, pluginID: c.pluginID, title: c.title, projectID: c.projectID,
                     scope: c.account, period: "Last 30 days · first attempts", fetchedAt: now,
                     metrics: CIWaitSample.metrics(samples))
    }
    private struct Runs: Decodable { let workflow_runs: [Run] }
    private struct Run: Decodable {
        let id: Int64
        let created_at: String
        let run_started_at: String?
        let run_attempt: Int?
        let pull_requests: [PR]
    }
    private struct PR: Decodable { let number: Int }
}

public struct CIWaitSample: Sendable, Equatable {
    public var id: String
    public var repository: String
    public var pr: Int
    public var seconds: Double
    public init(id: String, repository: String, pr: Int, seconds: Double) {
        self.id = id; self.repository = repository; self.pr = pr; self.seconds = seconds
    }
    /// Each PR receives equal weight in the overall average, independently of
    /// the number of workflows it runs. Duplicate run/PR identities count once.
    public static func metrics(_ input: [Self]) -> [UsageMetric] {
        var seen = Set<String>()
        let samples = input.filter { $0.seconds.isFinite && $0.seconds >= 0 && seen.insert($0.id).inserted }
        let groups = Dictionary(grouping: samples) { "\($0.repository)#\($0.pr)" }
        let prMetrics = groups.keys.sorted().map { key in
            let values = groups[key]!
            return UsageMetric(key, key, value: values.map(\.seconds).reduce(0, +) / Double(values.count), unit: "seconds", detail: "Mean workflow queue wait · \(values.count) runs")
        }
        let average = prMetrics.isEmpty ? nil : prMetrics.compactMap(\.value).reduce(0, +) / Double(prMetrics.count)
        let repositories = Set(samples.map(\.repository)).sorted().map { repo in
            let values = prMetrics.filter { $0.id.hasPrefix(repo + "#") }.compactMap(\.value)
            return UsageMetric("repo:\(repo)", repo, value: values.reduce(0, +) / Double(values.count), unit: "seconds", detail: "Mean across \(values.count) PRs")
        }
        return [.init("overall", "Average CI wait per PR", value: average, unit: "seconds", detail: "Created to started · \(prMetrics.count) PRs")] + repositories + prMetrics
    }
}
