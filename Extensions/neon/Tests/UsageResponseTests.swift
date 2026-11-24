import Foundation
import Testing
@testable import NeonUsage

struct UsageResponseTests {
    @Test func neonAggregatesTimeframesAndPreservesCursor() throws {
        let data = Data(#"{"projects":[{"periods":[{"consumption":[{"metrics":[{"metric_name":"compute_unit_seconds","value":84}]},{"metrics":[{"metric_name":"compute_unit_seconds","value":236}]}]}]}],"pagination":{"cursor":"next"}}"#.utf8)
        let result = try UsageResponseParser.neon(data)
        #expect(result.totals["compute_unit_seconds"] == 320)
        #expect(result.cursor == "next")
    }
}
