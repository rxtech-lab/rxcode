import Foundation
import os

/// Aggregates hot-path measurements without publishing changes to SwiftUI.
/// Durations are inclusive (nested operations overlap), not frame/render times.
@MainActor
final class StoryBoardPerformanceLog {
    private static let logger = Logger(subsystem: "com.claudework", category: "StoryBoardPerformance")

    private struct Sample {
        var count = 0
        var timedCount = 0
        var total = 0.0
        var maximum = 0.0
    }

    private var samples: [String: Sample] = [:]
    private var windowStart: UInt64?
    private var lastOffset: CGPoint?
    private var horizontalTravel = 0.0
    private var verticalTravel = 0.0
    private var offsetChanges = 0

    /// Geometry callbacks confirm movement even when scroll phases stay idle.
    /// This state is deliberately not observable and never requests a redraw.
    func recordScrollOffset(_ offset: CGPoint) {
        defer { lastOffset = offset }
        guard let previous = lastOffset, previous != offset else { return }
        if windowStart == nil { windowStart = DispatchTime.now().uptimeNanoseconds }
        horizontalTravel += abs(offset.x - previous.x)
        verticalTravel += abs(offset.y - previous.y)
        offsetChanges += 1
    }

    func log(_ message: String) {
        Self.logger.notice("PERFORMANCE: story-board \(message, privacy: .public)")
    }

    static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func record(_ operation: String, since start: UInt64? = nil) {
        if windowStart == nil { windowStart = DispatchTime.now().uptimeNanoseconds }
        let duration = start.map(Self.elapsed(since:)) ?? 0
        var sample = samples[operation, default: Sample()]
        sample.count += 1
        if start != nil { sample.timedCount += 1 }
        sample.total += duration
        sample.maximum = max(sample.maximum, duration)
        samples[operation] = sample
    }

    func flush(scope: String) {
        guard let windowStart else { return }
        let windowMs = Self.elapsed(since: windowStart)
        var details = samples.keys.sorted().map { key in
            let sample = samples[key]!
            let timing = sample.timedCount == 0 ? "" : " timedCalls=\(sample.timedCount) inclusiveMs=\(String(format: "%.2f", sample.total)) maxMs=\(String(format: "%.2f", sample.maximum))"
            return "\(key) calls=\(sample.count)\(timing)"
        }
        if offsetChanges > 0 {
            details.append("scroll-offset changes=\(offsetChanges) travelX=\(String(format: "%.1f", horizontalTravel)) travelY=\(String(format: "%.1f", verticalTravel))pt")
        }
        samples.removeAll(keepingCapacity: true)
        self.windowStart = nil
        horizontalTravel = 0
        verticalTravel = 0
        offsetChanges = 0
        log("scope=\(scope) windowMs=\(String(format: "%.2f", windowMs)) \(details.joined(separator: "; "))")
    }

    /// One low-frequency probe per mounted scrolling surface. Scheduling delay can
    /// indicate main-actor contention; it does not measure display frame rate.
    /// Cancellation follows the view's task lifetime.
    func monitor(scope: String) async {
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
                log("main-actor scheduling delay scope=\(scope) excessMs=\(String(format: "%.2f", delay))")
            }
            flush(scope: scope)
        }
    }
}
