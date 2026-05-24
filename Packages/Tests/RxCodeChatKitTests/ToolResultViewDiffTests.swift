import Testing
import RxCodeCore
@testable import RxCodeChatKit

@Suite("ToolResultView diff links")
struct ToolResultViewDiffTests {
    @Test("edit diff links open full-file diff mode")
    func editDiffLinksOpenFullFileDiffMode() {
        let hunks = [
            PreviewFile.EditHunk(oldString: "let value = 1", newString: "let value = 2")
        ]

        let file = ToolResultView.editDiffPreviewFile(
            path: "/tmp/example.swift",
            name: "example.swift",
            hunks: hunks
        )

        #expect(file.path == "/tmp/example.swift")
        #expect(file.name == "example.swift")
        #expect(file.editHunks == hunks)
        #expect(file.showFullFileDiff == true)
    }
}
