import Foundation
import Observation
import RxCodeCore

/// Every download and install RxCode runs — Claude Code and Codex, ACP
/// agents, local models and their runtimes — reported in one place so the
/// Downloads window can show them side by side.
///
/// Installers run their work through `track`, which gives every item a Cancel
/// button that cancels the work's task; installers stop their downloads and
/// child processes when that task is cancelled.
@MainActor @Observable
final class DownloadCenter {
    // Hosted tests exercise the static tracking API too. They must never load
    // or overwrite the user's history, including entries cleared by the app.
    static let shared = DownloadCenter(storageURL: AppSupport.isTestProcess ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "RxCode/downloads.json"))

    /// `shared` is what the app uses; separate instances are for tests.
    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL, let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved.map { item in
                var item = item
                if item.phase.isActive { item.phase = .interrupted }
                return item
            }
        }
    }

    @ObservationIgnored private let storageURL: URL?

    private func persist() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: storageURL, options: .atomic)
        } catch { persistenceError = error.localizedDescription }
    }

    private(set) var persistenceError: String?

    struct Recovery: Codable, Equatable {
        let summary: HFModelSummary
        let variant: HFModelVariant
        let directory: URL
        let stagingDirectory: URL
    }

    enum Kind: String, Codable, Sendable {
        case agentRuntime
        case acpAgent
        case localModel
        case modelRuntime

        var label: String {
            switch self {
            case .agentRuntime: "Agent CLI"
            case .acpAgent: "ACP agent"
            case .localModel: "Local model"
            case .modelRuntime: "Model runtime"
            }
        }

        var systemImage: String {
            switch self {
            case .agentRuntime: "terminal"
            case .acpAgent: "puzzlepiece.extension"
            case .localModel: "cpu"
            case .modelRuntime: "gearshape.2"
            }
        }
    }

    enum Phase: Codable, Equatable, Sendable {
        /// Looking up versions or preparing; no byte counts yet.
        case preparing
        case downloading
        /// Unpacking or installing after the bytes arrived.
        case installing
        case finished
        case failed(String)
        case cancelled
        case interrupted

        var isActive: Bool {
            switch self {
            case .preparing, .downloading, .installing: true
            case .finished, .failed, .cancelled, .interrupted: false
            }
        }
    }

    struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let kind: Kind
        let startedAt: Date
        var phase: Phase = .preparing
        var receivedBytes: Int64 = 0
        var totalBytes: Int64?
        var finishedAt: Date?
        var recovery: Recovery?

        /// Determinate only while downloading with a known total.
        var fraction: Double? {
            guard phase == .downloading, let totalBytes, totalBytes > 0 else { return nil }
            return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
        }
    }

    /// Newest first.
    private(set) var items: [Item] = []
    /// Bumped when a new item starts; presenters open the window on change.
    private(set) var presentRequest = 0

    @ObservationIgnored private var cancelHandlers: [UUID: @MainActor () -> Void] = [:]
    /// Last time each item's byte count was published, for throttling.
    @ObservationIgnored private var lastByteUpdate: [UUID: Date] = [:]
    /// Byte-only updates closer together than this are dropped so the
    /// progress text doesn't churn. Phase changes always go through.
    static let byteUpdateInterval: TimeInterval = 0.5

    /// Session-only samples: retained bytes from a resumed download are not throughput.
    @ObservationIgnored private var speedSamples: [UUID: [(time: Date, bytes: Int64)]] = [:]

    func bytesPerSecond(_ id: UUID, at now: Date = Date()) -> Double? {
        guard let samples = speedSamples[id], samples.count >= 2,
              let first = samples.first, let last = samples.last else { return nil }
        guard now.timeIntervalSince(last.time) < 5 else { return 0 }
        let elapsed = now.timeIntervalSince(first.time)
        guard elapsed > 0 else { return nil }
        return Double(last.bytes - first.bytes) / elapsed
    }

    var activeCount: Int { items.filter { $0.phase.isActive }.count }

    func isCancellable(_ id: UUID) -> Bool { cancelHandlers[id] != nil }

    // MARK: - Reporting

    @discardableResult
    func begin(_ title: String, kind: Kind, recovery: Recovery? = nil, cancel: (@MainActor () -> Void)? = nil) -> UUID {
        if let recovery, let existing = items.firstIndex(where: { $0.recovery?.stagingDirectory == recovery.stagingDirectory && !$0.phase.isActive }) {
            let id = items[existing].id
            speedSamples[id] = nil
            lastByteUpdate[id] = nil
            items[existing].recovery = recovery
            items[existing].phase = .preparing
            items[existing].finishedAt = nil
            if let cancel { cancelHandlers[id] = cancel }
            persist()
            return id
        }
        let item = Item(id: UUID(), title: title, kind: kind, startedAt: Date(), recovery: recovery)
        items.insert(item, at: 0)
        if let cancel { cancelHandlers[item.id] = cancel }
        presentRequest += 1
        persist()
        return item.id
    }

    func update(_ id: UUID, phase: Phase, receivedBytes: Int64? = nil, totalBytes: Int64? = nil, transferredBytes: Int64? = nil, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].phase.isActive else { return }
        // A new file starts at zero network bytes even when disk progress is nonzero.
        if transferredBytes == 0 {
            speedSamples[id] = nil
            lastByteUpdate[id] = nil
        }
        let reachedTotal = receivedBytes != nil && receivedBytes == (totalBytes ?? items[index].totalBytes)
        if items[index].phase == phase, !reachedTotal, receivedBytes != nil,
           let last = lastByteUpdate[id], now.timeIntervalSince(last) < Self.byteUpdateInterval {
            return
        }
        lastByteUpdate[id] = now
        if phase == .downloading, let receivedBytes {
            let receivedBytes = transferredBytes ?? receivedBytes
            var samples = speedSamples[id] ?? []
            if let last = samples.last, receivedBytes < last.bytes { samples = [] }
            samples.append((now, receivedBytes))
            // Keep a baseline and the recent five seconds of progress.
            while samples.count > 2, now.timeIntervalSince(samples[1].time) > 5 {
                samples.removeFirst()
            }
            speedSamples[id] = samples
        } else if phase != .downloading {
            speedSamples[id] = nil
        }
        items[index].phase = phase
        if let receivedBytes { items[index].receivedBytes = receivedBytes }
        if let totalBytes { items[index].totalBytes = totalBytes > 0 ? totalBytes : nil }
        persist()
    }

    func finish(_ id: UUID) {
        complete(id, phase: .finished)
    }

    func fail(_ id: UUID, error: Error) {
        let cancelled = error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || (error as? LocalModelDownloader.DownloadError).map { if case .cancelled = $0 { true } else { false } } == true
        complete(id, phase: cancelled ? .cancelled : .failed(error.localizedDescription))
    }

    /// Makes an active item cancellable from the window.
    func setCancelHandler(_ id: UUID, _ handler: @escaping @MainActor () -> Void) {
        guard items.contains(where: { $0.id == id && $0.phase.isActive }) else { return }
        cancelHandlers[id] = handler
    }

    // MARK: - Actions

    func cancel(_ id: UUID) {
        cancelHandlers[id]?()
    }

    func cancelAll() {
        for handler in cancelHandlers.values { handler() }
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.phase.isActive else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    func clearCompleted() {
        items.removeAll { $0.phase == .finished || ($0.recovery == nil && !$0.phase.isActive) }
        persist()
    }

    // MARK: - Off-main entry points

    /// Runs `operation` as a tracked, cancellable item. Cancelling from the
    /// window — or cancelling the caller — cancels `operation`'s task and
    /// throws `CancellationError`, so callers never mistake a cancel for a
    /// failure worth falling back from.
    nonisolated static func track<T: Sendable>(
        _ title: String,
        kind: Kind,
        _ operation: @escaping @Sendable (UUID) async throws -> T
    ) async throws -> T {
        let id = await begin(title, kind: kind)
        let task = Task { try await operation(id) }
        await MainActor.run { shared.setCancelHandler(id) { task.cancel() } }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            await finish(id)
            return value
        } catch {
            if task.isCancelled {
                await MainActor.run { shared.complete(id, phase: .cancelled) }
                throw CancellationError()
            }
            await fail(id, error: error)
            throw error
        }
    }

    nonisolated static func begin(_ title: String, kind: Kind) async -> UUID {
        await MainActor.run { shared.begin(title, kind: kind) }
    }

    nonisolated static func update(_ id: UUID, phase: Phase, receivedBytes: Int64? = nil, totalBytes: Int64? = nil, transferredBytes: Int64? = nil) {
        Task { @MainActor in shared.update(id, phase: phase, receivedBytes: receivedBytes, totalBytes: totalBytes, transferredBytes: transferredBytes) }
    }

    nonisolated static func finish(_ id: UUID) async {
        await MainActor.run { shared.finish(id) }
    }

    nonisolated static func fail(_ id: UUID, error: Error) async {
        await MainActor.run { shared.fail(id, error: error) }
    }

    // MARK: - Private

    private func complete(_ id: UUID, phase: Phase) {
        cancelHandlers[id] = nil
        speedSamples[id] = nil
        lastByteUpdate[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = phase
        items[index].finishedAt = Date()
        persist()
    }
}
