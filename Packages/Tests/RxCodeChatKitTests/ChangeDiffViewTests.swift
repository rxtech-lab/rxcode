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

        // Each diff row renders marker + body as one concatenated Text, so we
        // look for the marker-prefixed forms here.
        #expect(strings.contains { $0.contains("one") })
        #expect(strings.contains { $0.contains("two") })
        #expect(strings.contains { $0.contains("TWO") })
    }

    @Test("hunk diff renders removed-then-added lines")
    func hunkDiffRendersRemovedThenAdded() throws {
        let view = ChangeDiffView(hunks: [
            PreviewFile.EditHunk(oldString: "old", newString: "new")
        ])
        let strings = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(strings.contains { $0.contains("old") })
        #expect(strings.contains { $0.contains("new") })
    }
}
