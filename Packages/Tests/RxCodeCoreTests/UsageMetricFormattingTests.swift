import Foundation
import Testing
@testable import RxCodeCore

@Suite("Usage metric formatting")
struct UsageMetricFormattingTests {
    private func quantity(_ value: Double, _ unit: String) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
    }

    @Test func durationsUseHoursWhileShortWaitsRemainReadable() {
        #expect(UsageMetric("compute", "Compute", value: 1_911_500, unit: "CU seconds").formattedValue
                == quantity(1_911_500.0 / 3600, "CU hrs"))
        #expect(UsageMetric("time", "Time", value: 7200, unit: "seconds").formattedValue == quantity(2, "hrs"))
        #expect(UsageMetric("wait", "Wait", value: 90, unit: "seconds").formattedValue == quantity(1.5, "min"))
    }

    @Test func storageScalesWithDecimalUnitsAndPreservesTimeDimension() {
        for (value, expected, unit) in [(0.0, 0.0, "bytes"), (999, 999, "bytes"),
                                       (1000, 1, "KB"), (2_500_000, 2.5, "MB"),
                                       (41_025_000_000, 41.025, "GB"), (1e12, 1, "TB")] {
            #expect(UsageMetric("storage", "Storage", value: value, unit: "bytes").formattedValue
                    == quantity(expected, unit))
        }
        #expect(UsageMetric("storage", "Storage", value: 247_000_000, unit: "byte-hours").formattedValue
                == quantity(247, "MB-hrs"))
        #expect(UsageMetric("storage", "Storage", value: 2e9, unit: "byte-hours").formattedValue
                == quantity(2, "GB-hrs"))
    }

    @Test func displayConversionPreservesRawSnapshotAndHandlesMissingData() throws {
        let metric = UsageMetric("compute", "Compute", value: 7200, unit: "CU seconds")
        let decoded = try JSONDecoder().decode(UsageMetric.self, from: JSONEncoder().encode(metric))
        #expect(decoded.value == 7200)
        #expect(decoded.unit == "CU seconds")
        #expect(decoded.formattedValue == quantity(2, "CU hrs"))
        for value: Double? in [nil, .infinity, .nan] {
            #expect(UsageMetric("storage", "Storage", value: value, unit: "bytes").formattedValue == "Unavailable")
        }
    }
}
