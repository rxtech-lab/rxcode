import Foundation
import os

/// Aggregates hot-path measurements without publishing changes to SwiftUI.
/// Durations are inclusive (nested operations overlap), not frame/render times.
@MainActor
final class ChatHistoryPerformanceLog {
    private static let logger = Logger(subsystem: "com.claudework", category: "ChatHistoryPerformance")

    private struct Sample {
        var count = 0
        var total = 0.0
        var maximum = 0.0
    }

    private var samples: [String: Sample] = [:]

    func log(_ message: String) {
        Self.logger.notice("PERFORMANCE: chat-history \(message, privacy: .public)")
    }

    static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func record(_ operation: String, since start: UInt64? = nil, project: UUID) {
        let duration = start.map(Self.elapsed(since:)) ?? 0
        var sample = samples[operation, default: Sample()]
        sample.count += 1
        sample.total += duration
        sample.maximum = max(sample.maximum, duration)
        samples[operation] = sample
    }

    func flush(project: UUID) {
        guard !samples.isEmpty else { return }
        let details = samples.keys.sorted().map { key in
            let sample = samples[key]!
            return "\(key) calls=\(sample.count) inclusiveMs=\(String(format: "%.2f", sample.total)) maxMs=\(String(format: "%.2f", sample.maximum))"
        }.joined(separator: "; ")
        samples.removeAll(keepingCapacity: true)
        log("project=\(project) \(details)")
    }

    /// One low-frequency probe per mounted project list. Scheduling delay can
    /// indicate main-actor contention; it does not measure display frame rate.
    /// Cancellation follows the view's task lifetime.
    func monitor(project: UUID) async {
        while !Task.isCancelled {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let delay = Self.elapsed(since: start) - 1_000
            if delay >= 50 {
                log("main-actor scheduling delay project=\(project) excessMs=\(String(format: "%.2f", delay))")
            }
            flush(project: project)
        }
    }
}
