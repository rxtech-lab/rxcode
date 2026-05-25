import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("ChangeDiffView rendering")
struct ChangeDiffViewTests {
    @Test("unified diff renders parsed lines through shared DiffView")
    func unifiedDiffRendersParsedLines() throws {
        let view = ChangeDiffView(unifiedDiff: "@@ -1,3 +1,3 @@\n one\n-two\n+TWO")
        let strings = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        // Body text strips the leading marker. Old line numbers come from the
        // hunk header (1 = first context row, 2 = removed row); the added row
        // gets new line number 2.
        #expect(strings.contains("one"))
        #expect(strings.contains("two"))
        #expect(strings.contains("TWO"))
    }

    @Test("hunk diff renders removed-then-added lines")
    func hunkDiffRendersRemovedThenAdded() throws {
        let view = ChangeDiffView(hunks: [
            PreviewFile.EditHunk(oldString: "old", newString: "new")
        ])
        let strings = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(strings.contains("old"))
        #expect(strings.contains("new"))
    }
}
