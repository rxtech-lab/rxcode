import Foundation
import Testing
@testable import RxCodeCore

struct LocalFileLinkTests {
    @Test("Angle-wrapped Markdown destinations preserve spaces and location suffixes")
    func parsesAngleWrappedDestination() {
        #expect(LocalFileLink.parsePathString("</tmp/Sample Preview.pdf>")?.path == "/tmp/Sample Preview.pdf")
        #expect(LocalFileLink.parsePathString("</tmp/example.swift:12:3>") == LocalFileLink(
            path: "/tmp/example.swift", line: 12, column: 3
        ))
    }

    @Test("A renderer-resolved angle destination recovers its absolute path")
    func parsesRendererResolvedDestination() {
        let url = URL(fileURLWithPath: "</tmp/Sample Preview.pdf>", relativeTo: URL(fileURLWithPath: "/workspace/"))
        #expect(LocalFileLink.parse(url)?.path == "/tmp/Sample Preview.pdf")
        let encoded = URL(string: "file:///workspace/%3C/tmp/Sample%20Preview.pdf%3E")!
        #expect(LocalFileLink.parse(encoded)?.path == "/tmp/Sample Preview.pdf")
    }

    @Test("Literal angle brackets in ordinary filenames remain intact")
    func preservesLiteralFilenameCharacters() {
        for path in ["/tmp/Sample Preview.pdf>", "/tmp/a<b>.txt", "/tmp/<report>"] {
            #expect(LocalFileLink.parse(URL(fileURLWithPath: path))?.path == path)
        }
    }

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
