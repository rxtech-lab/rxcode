import Foundation

/// Coalesces identical refreshes for one integration and limits the number of active provider sessions.
@MainActor
public final class ExtensionUsageScheduler {
    private final class Job {
        let id = UUID()
        let provider: String
        let workspace: URL
        let generation: String
        let integration: UsageIntegration
        let work: @MainActor () async throws -> UsagePluginSnapshot
        var waiters: [UUID: CheckedContinuation<UsagePluginSnapshot, Error>] = [:]
        var task: Task<Void, Never>?

        init(provider: String, workspace: URL, generation: String, integration: UsageIntegration,
             work: @escaping @MainActor () async throws -> UsagePluginSnapshot) {
            self.provider = provider
            self.workspace = workspace
            self.generation = generation
            self.integration = integration
            self.work = work
        }
    }
    private var jobs: [Job] = []
    private var running = 0

    public init() {}

    public func fetch(provider: String, workspace: URL, generation: String, integration: UsageIntegration,
                      work: @escaping @MainActor () async throws -> UsagePluginSnapshot) async throws -> UsagePluginSnapshot {
        try Task.checkCancellation()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let job: Job
                if let existing = jobs.first(where: { !$0.waiters.isEmpty && $0.provider == provider && $0.workspace == workspace &&
                    $0.generation == generation && $0.integration == integration }) {
                    job = existing
                } else {
                    job = Job(provider: provider, workspace: workspace, generation: generation, integration: integration, work: work)
                    jobs.append(job)
                }
                job.waiters[waiter] = continuation
                startPending()
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(waiter) }
        }
    }

    public func invalidate(provider: String, workspace: URL? = nil) {
        for job in jobs where job.provider == provider && (workspace == nil || job.workspace == workspace) {
            job.task?.cancel()
            for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
            job.waiters.removeAll()
        }
        jobs.removeAll { $0.task == nil && $0.waiters.isEmpty }
        startPending()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let job = jobs.first(where: { $0.waiters[id] != nil }) else { return }
        job.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.task?.cancel()
            if job.task == nil { jobs.removeAll { $0 === job } }
        }
    }

    private func startPending() {
        while running < 2, let job = jobs.first(where: { $0.task == nil && !$0.waiters.isEmpty &&
            !hasActiveFetch(for: $0.integration.id) }) {
            running += 1
            job.task = Task {
                let result: Result<UsagePluginSnapshot, Error>
                do {
                    try Task.checkCancellation()
                    let snapshot = try await job.work()
                    try Task.checkCancellation()
                    result = .success(snapshot)
                } catch { result = .failure(error) }
                jobs.removeAll { $0 === job }
                running -= 1
                for waiter in job.waiters.values { waiter.resume(with: result) }
                job.waiters.removeAll()
                startPending()
            }
        }
    }

    private func hasActiveFetch(for id: UUID) -> Bool {
        jobs.contains { $0.task != nil && $0.integration.id == id }
    }
}
