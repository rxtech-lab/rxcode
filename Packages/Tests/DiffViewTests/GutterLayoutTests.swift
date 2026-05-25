import Testing
@testable import DiffView

@Suite("GutterLayout")
@MainActor
struct GutterLayoutTests {
    @Test("change set with both sides uses two columns")
    func changeUsesTwoColumns() {
        let lines = [
            DiffLine(text: " a", kind: .context, oldLineNumber: 1, newLineNumber: 1),
            DiffLine(text: "-b", kind: .removed, oldLineNumber: 2, newLineNumber: nil),
            DiffLine(text: "+B", kind: .added, oldLineNumber: nil, newLineNumber: 2),
        ]
        let layout = GutterLayout(lines: lines)

        #expect(layout.showOld)
        #expect(layout.showNew)
        #expect(layout.columnCount == 2)
    }

    @Test("new-file diff (only added rows) collapses to one column")
    func newFileUsesOneColumn() {
        let lines = [
            DiffLine(text: "+alpha", kind: .added, oldLineNumber: nil, newLineNumber: 1),
            DiffLine(text: "+beta",  kind: .added, oldLineNumber: nil, newLineNumber: 2),
        ]
        let layout = GutterLayout(lines: lines)

        #expect(layout.showOld == false)
        #expect(layout.showNew)
        #expect(layout.columnCount == 1)
    }

    @Test("full deletion (only removed rows) collapses to one column")
    func deletedFileUsesOneColumn() {
        let lines = [
            DiffLine(text: "-alpha", kind: .removed, oldLineNumber: 1, newLineNumber: nil),
            DiffLine(text: "-beta",  kind: .removed, oldLineNumber: 2, newLineNumber: nil),
        ]
        let layout = GutterLayout(lines: lines)

        #expect(layout.showOld)
        #expect(layout.showNew == false)
        #expect(layout.columnCount == 1)
    }

    @Test("additions on top of context (no removals) collapses to new-only column")
    func additionsOverContextUsesOneColumn() {
        let lines = [
            DiffLine(text: " keep", kind: .context, oldLineNumber: 1, newLineNumber: 1),
            DiffLine(text: "+new",  kind: .added,   oldLineNumber: nil, newLineNumber: 2),
            DiffLine(text: " tail", kind: .context, oldLineNumber: 2, newLineNumber: 3),
        ]
        let layout = GutterLayout(lines: lines)

        #expect(layout.showOld == false)
        #expect(layout.showNew)
        #expect(layout.columnCount == 1)
    }

    @Test("hunk-only edit preview with no line numbers shows no gutter")
    func hunkOnlyShowsNoGutter() {
        let lines = [
            DiffLine(text: "-foo", kind: .removed),
            DiffLine(text: "+FOO", kind: .added),
        ]
        let layout = GutterLayout(lines: lines)

        #expect(layout.columnCount == 0)
    }

    @Test("horizontal scroll body expands for long right-side content")
    func horizontalScrollBodyWidthExpandsForLongContent() {
        let lines = [
            DiffLine(
                text: "+let value = \"this is a long line that should require horizontal scrolling on mobile\"",
                kind: .added,
                newLineNumber: 1
            ),
        ]
        let layout = GutterLayout(lines: lines)

        #expect(DiffView.horizontalScrollBodyWidth(for: lines, layout: layout) > 320)
    }
}
