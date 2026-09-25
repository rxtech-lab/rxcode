import Foundation

/// Low-overhead, process-wide counters for performance-sensitive paths.
///
/// Hot UI code records only numeric values under fixed keys. The app drains the
/// aggregate periodically and writes a single bounded diagnostic record, which
/// avoids doing file I/O or constructing detailed log strings while scrolling
/// and streaming.
public enum PerformanceDiagnostics {
    public struct Measurement: Codable, Sendable, Equatable {
        public let count: Int64
        public let total: Double
        public let maximum: Double

        public init(count: Int64, total: Double, maximum: Double) {
            self.count = count
            self.total = total
            self.maximum = maximum
        }
    }

    public struct Snapshot: Codable, Sendable, Equatable {
        public let counters: [String: Int64]
        public let measurements: [String: Measurement]

        public init(
            counters: [String: Int64],
            measurements: [String: Measurement]
        ) {
            self.counters = counters
            self.measurements = measurements
        }
    }

    private final class Accumulator: @unchecked Sendable {
        private struct MutableMeasurement {
            var count: Int64 = 0
            var total: Double = 0
            var maximum: Double = 0
        }

        private let lock = NSLock()
        private var counters: [String: Int64] = [:]
        private var measurements: [String: MutableMeasurement] = [:]

        func increment(_ key: String, by amount: Int64) {
            lock.lock()
            counters[key, default: 0] += amount
            lock.unlock()
        }

        func record(_ key: String, value: Double) {
            lock.lock()
            var measurement = measurements[key, default: MutableMeasurement()]
            measurement.count += 1
            measurement.total += value
            measurement.maximum = max(measurement.maximum, value)
            measurements[key] = measurement
            lock.unlock()
        }

        func drain() -> Snapshot {
            lock.lock()
            let counterSnapshot = counters
            let measurementSnapshot = measurements.mapValues {
                Measurement(count: $0.count, total: $0.total, maximum: $0.maximum)
            }
            counters.removeAll(keepingCapacity: true)
            measurements.removeAll(keepingCapacity: true)
            lock.unlock()
            return Snapshot(counters: counterSnapshot, measurements: measurementSnapshot)
        }
    }

    private static let accumulator = Accumulator()

    public static func increment(_ key: String, by amount: Int64 = 1) {
        accumulator.increment(key, by: amount)
    }

    /// Records a numeric distribution. The snapshot keeps count, total, and
    /// maximum, which is enough to calculate an interval average without
    /// retaining individual events.
    public static func record(_ key: String, value: Double) {
        accumulator.record(key, value: value)
    }

    /// Returns and resets the current interval's aggregate values.
    public static func drain() -> Snapshot {
        accumulator.drain()
    }
}

public extension PerformanceDiagnostics.Snapshot {
    /// Folds a second accumulator's interval into this one.
    ///
    /// The chat transcript and markdown renderers moved to RxAgentSDK, which
    /// records into its own `RxAgentUISupport.PerformanceDiagnostics` registry.
    /// Without this merge the `scroll.*` and `markdown.*` keys would simply
    /// stop appearing in the diagnostic record. Counters add; measurements add
    /// their count and total and keep the larger maximum.
    func merging(
        counters otherCounters: [String: Int64],
        measurements otherMeasurements: [String: PerformanceDiagnostics.Measurement]
    ) -> Self {
        var mergedCounters = counters
        for (key, value) in otherCounters {
            mergedCounters[key, default: 0] += value
        }

        var mergedMeasurements = measurements
        for (key, value) in otherMeasurements {
            guard let existing = mergedMeasurements[key] else {
                mergedMeasurements[key] = value
                continue
            }
            mergedMeasurements[key] = PerformanceDiagnostics.Measurement(
                count: existing.count + value.count,
                total: existing.total + value.total,
                maximum: max(existing.maximum, value.maximum)
            )
        }

        return Self(counters: mergedCounters, measurements: mergedMeasurements)
    }
}
