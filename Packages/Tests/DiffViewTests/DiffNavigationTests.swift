import Testing
@testable import DiffView

@Suite("Diff navigation")
struct DiffNavigationTests {
    @Test("contiguous add and remove rows form one change block")
    func contiguousChangedRowsAreOneBlock() {
        let lines = [
            DiffLine(text: " a", kind: .context, oldLineNumber: 1, newLineNumber: 1),
            DiffLine(text: "-b", kind: .removed, oldLineNumber: 2),
            DiffLine(text: "+B", kind: .added, newLineNumber: 2),
            DiffLine(text: " c", kind: .context, oldLineNumber: 3, newLineNumber: 3),
            DiffLine(text: "+d", kind: .added, newLineNumber: 4),
        ]

        #expect(DiffView.changeBlockOffsets(in: lines) == [1, 4])
    }

    @Test("hunk headers do not count as change targets")
    func hunkHeadersAreSkipped() {
        let lines = [
            DiffLine(text: "@@ -1,2 +1,2 @@", kind: .hunk),
            DiffLine(text: " a", kind: .context, oldLineNumber: 1, newLineNumber: 1),
            DiffLine(text: "-b", kind: .removed, oldLineNumber: 2),
            DiffLine(text: "+B", kind: .added, newLineNumber: 2),
        ]

        #expect(DiffView.changeBlockOffsets(in: lines) == [2])
    }
}
