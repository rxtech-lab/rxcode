import Foundation
import Testing
@testable import RxCodeCore

struct LocalFileLinkTests {
    @Test("file URLs with spaces and line suffix parse as local file links")
    func parsesFileURLWithSpacesAndLineSuffix() {
        let url = URL(fileURLWithPath: "/Users/example/Application Support/RxCode/file.swift:12")
        let link = LocalFileLink.parse(url)

        #expect(link == LocalFileLink(
            path: "/Users/example/Application Support/RxCode/file.swift",
            line: 12
        ))
    }
}
