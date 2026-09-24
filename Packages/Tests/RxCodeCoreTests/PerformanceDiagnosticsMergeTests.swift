import Testing
@testable import RxCodeCore

/// `merging` exists because the chat transcript and markdown renderers moved to
/// RxAgentSDK, which records into its own `PerformanceDiagnostics` accumulator.
/// `PerformanceDiagnosticsService` drains both and folds them into one record.
@Suite("Performance diagnostics merge")
struct PerformanceDiagnosticsMergeTests {
    private typealias Measurement = PerformanceDiagnostics.Measurement
    private typealias Snapshot = PerformanceDiagnostics.Snapshot

    @Test("Counters present in both registries add")
    func countersAdd() {
        let merged = Snapshot(counters: ["scroll.skipped": 3], measurements: [:])
            .merging(counters: ["scroll.skipped": 4], measurements: [:])

        #expect(merged.counters["scroll.skipped"] == 7)
    }

    @Test("Counters present in only one registry survive")
    func disjointCountersSurvive() {
        let merged = Snapshot(counters: ["chat.settled_rebuild.total": 1], measurements: [:])
            .merging(counters: ["markdown.cache.hit": 2], measurements: [:])

        #expect(merged.counters["chat.settled_rebuild.total"] == 1)
        #expect(merged.counters["markdown.cache.hit"] == 2)
    }

    @Test("Measurements add count and total but keep the larger maximum")
    func measurementsFold() {
        let merged = Snapshot(
            counters: [:],
            measurements: ["markdown.parse.duration_ms": Measurement(count: 2, total: 10, maximum: 8)]
        ).merging(
            counters: [:],
            measurements: ["markdown.parse.duration_ms": Measurement(count: 3, total: 5, maximum: 4)]
        )

        #expect(
            merged.measurements["markdown.parse.duration_ms"]
                == Measurement(count: 5, total: 15, maximum: 8)
        )
    }

    @Test("Merging an empty interval is a no-op")
    func emptyMergeIsIdentity() {
        let original = Snapshot(
            counters: ["markdown.cache.miss": 9],
            measurements: ["markdown.parse.input_bytes": Measurement(count: 1, total: 512, maximum: 512)]
        )

        #expect(original.merging(counters: [:], measurements: [:]) == original)
    }
}
