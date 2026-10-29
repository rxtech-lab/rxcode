import Foundation
import os

/// Debug logging for briefing timeline scroll performance. Every line starts
/// with `PERFORMANCE:` so it can be filtered in Xcode or Console
/// (`subsystem:com.claudework category:BriefingPerformance`).
enum BriefingPerformanceLog {
    private static let logger = Logger(subsystem: "com.claudework", category: "BriefingPerformance")

    static func log(_ message: @autoclosure () -> String) {
        let message = message()
        logger.notice("PERFORMANCE: \(message, privacy: .public)")
    }

    /// Runs `work` and logs how long it took. Durations under `threshold`
    /// milliseconds are not logged.
    @discardableResult
    static func measure<T>(_ label: @autoclosure () -> String, threshold: Double = 0, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try work()
        let elapsed = milliseconds(since: start)
        if elapsed >= threshold {
            log("\(label()) took \(format(elapsed))ms")
        }
        return result
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func format(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }
}
