import Foundation
import Testing
@testable import TursoUsage

struct UsageResponseTests {
    @Test func tursoDoesNotDoubleCountInstances() throws {
        let data = Data(#"{"database":{"instances":[{"usage":{"rows_read":10}}],"total":{"rows_read":10,"rows_written":2,"storage_bytes":4096,"bytes_synced":0}}}"#.utf8)
        #expect(try UsageResponseParser.turso(data, database: true).first?.value == 10)
    }
}
