import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("ChangeDiffView rendering")
struct ChangeDiffViewTests {
    @Test("unified diff rows render a line number gutter")
    func unifiedDiffRowsRenderLineNumbers() throws {
        let view = ChangeDiffView(unifiedDiff: " one\n+two\n-three")
        let strings = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(strings.contains("1"))
        #expect(strings.contains("2"))
        #expect(strings.contains("3"))
        #expect(strings.contains("+two"))
    }

    @Test("hunk diff rows render a line number gutter")
    func hunkDiffRowsRenderLineNumbers() throws {
        let view = ChangeDiffView(hunks: [
            PreviewFile.EditHunk(oldString: "old", newString: "new")
        ])
        let strings = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(strings.contains("1"))
        #expect(strings.contains("2"))
        #expect(strings.contains("- old"))
        #expect(strings.contains("+ new"))
    }
}
