import Testing
import RxCodeCore
@testable import DiffView

@Suite("DiffComputation")
@MainActor
struct DiffComputationTests {
    @Test("snapshot diff numbers both gutters")
    func snapshotDiffNumbersBothGutters() {
        let lines = DiffComputation.buildSnapshotDiffLines(
            original: "one\ntwo\nthree\n",
            current: "one\nTWO\nthree\n"
        )

        #expect(lines.map(\.text) == [" one", "-two", "+TWO", " three"])
        #expect(lines[0].oldLineNumber == 1 && lines[0].newLineNumber == 1)
        #expect(lines[1].oldLineNumber == 2 && lines[1].newLineNumber == nil)
        #expect(lines[2].oldLineNumber == nil && lines[2].newLineNumber == 2)
        #expect(lines[3].oldLineNumber == 3 && lines[3].newLineNumber == 3)
    }

    @Test("new-file snapshot diff yields only added lines")
    func newFileSnapshotDiffOnlyAdded() {
        let lines = DiffComputation.buildSnapshotDiffLines(
            original: "",
            current: "alpha\nbeta\n"
        )

        #expect(lines.allSatisfy { $0.kind == .added })
        #expect(lines.allSatisfy { $0.oldLineNumber == nil })
        #expect(lines.compactMap(\.newLineNumber) == [1, 2])
    }

    @Test("snapshot diff added/removed counts lock the sidebar contract")
    func snapshotDiffCountsMatchSidebar() {
        let lines = DiffComputation.buildSnapshotDiffLines(
            original: "a\nb\nc\n",
            current: "a\nB\nc\n"
        )
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        #expect(added == 1)
        #expect(removed == 1)
    }

    @Test("edit hunk diff strips common indent")
    func editHunkStripsCommonIndent() {
        let hunks = [
            PreviewFile.EditHunk(oldString: "    foo\n    bar", newString: "    FOO\n    bar")
        ]
        let lines = DiffComputation.buildEditDiffLines(from: hunks)

        #expect(lines.map(\.text) == ["-foo", "-bar", "+FOO", "+bar"])
    }

    @Test("edit hunk diff renders file creation as all-added with new gutter")
    func editHunkRendersFileCreationAsAllAdded() {
        let hunks = [
            PreviewFile.EditHunk(oldString: "", newString: "alpha\nbeta\ngamma\n")
        ]
        let lines = DiffComputation.buildEditDiffLines(from: hunks)

        #expect(lines.map(\.kind) == [.added, .added, .added])
        #expect(lines.map(\.text) == ["+alpha", "+beta", "+gamma"])
        #expect(lines.compactMap(\.newLineNumber) == [1, 2, 3])
        #expect(lines.allSatisfy { $0.oldLineNumber == nil })
    }

    @Test("edit hunk diff renders file deletion as all-removed with old gutter")
    func editHunkRendersFileDeletionAsAllRemoved() {
        let hunks = [
            PreviewFile.EditHunk(oldString: "alpha\nbeta\n", newString: "")
        ]
        let lines = DiffComputation.buildEditDiffLines(from: hunks)

        #expect(lines.map(\.kind) == [.removed, .removed])
        #expect(lines.map(\.text) == ["-alpha", "-beta"])
        #expect(lines.compactMap(\.oldLineNumber) == [1, 2])
        #expect(lines.allSatisfy { $0.newLineNumber == nil })
    }

    @Test("full-file edit diff reconstructs the pre-edit file")
    func fullFileEditDiffReconstructsPreEdit() {
        let hunk = PreviewFile.EditHunk(oldString: "two", newString: "TWO")
        let lines = DiffComputation.buildFullFileEditDiffLines(
            currentContent: "one\nTWO\nthree\n",
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [" one", "-two", "+TWO", " three"])
    }

    @Test("full-file edit diff reconstructs multiple edits in reverse order")
    func fullFileEditDiffReconstructsMultipleEdits() {
        let hunks = [
            PreviewFile.EditHunk(oldString: "alpha", newString: "ALPHA"),
            PreviewFile.EditHunk(oldString: "gamma", newString: "GAMMA"),
        ]
        let lines = DiffComputation.buildFullFileEditDiffLines(
            currentContent: "ALPHA\nbeta\nGAMMA\n",
            hunks: hunks
        )

        #expect(lines.map(\.text) == [
            "-alpha",
            "+ALPHA",
            " beta",
            "-gamma",
            "+GAMMA",
        ])
    }

    @Test("full-file edit diff shows orphan change when reconstruction fails")
    func fullFileEditDiffShowsOrphanWhenReconstructionFails() {
        let hunk = PreviewFile.EditHunk(oldString: "before", newString: "after")
        let lines = DiffComputation.buildFullFileEditDiffLines(
            currentContent: "import SwiftUI\n\nstruct Example {}\n",
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            "@@ unmatched change @@",
            "-before",
            "+after",
            " import SwiftUI",
            " ",
            " struct Example {}",
        ])
    }

    @Test("full-file edit diff shows pure deletion as orphan above full file")
    func fullFileEditDiffShowsPureDeletionAsOrphan() {
        let hunk = PreviewFile.EditHunk(
            oldString: "        guard Self.hasExplicitMemoryIntent(userMessage) else { return }",
            newString: ""
        )
        let current = "        let userMessage = lastUserMessageText(in: messages)\n        let finalResponse = lastAssistantResponseText(in: messages)\n        let sourceMessageId = nil\n"
        let lines = DiffComputation.buildFullFileEditDiffLines(
            currentContent: current,
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            "@@ unmatched change @@",
            "-        guard Self.hasExplicitMemoryIntent(userMessage) else { return }",
            "         let userMessage = lastUserMessageText(in: messages)",
            "         let finalResponse = lastAssistantResponseText(in: messages)",
            "         let sourceMessageId = nil",
        ])
    }

    @Test("full-file edit diff renders a Write as all-added lines")
    func fullFileEditDiffRendersWriteAsAllAdded() {
        let content = "line one\nline two\nline three\n"
        let hunk = PreviewFile.EditHunk(oldString: "", newString: content)
        let lines = DiffComputation.buildFullFileEditDiffLines(
            currentContent: content,
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            "+line one",
            "+line two",
            "+line three",
        ])
    }

    @Test("snapshot diff line numbers track both sides")
    func snapshotDiffLineNumbersTrackBothSides() {
        let original = "alpha\nbeta\ngamma\n"
        let current = "alpha\nBETA\ngamma\ndelta\n"
        let lines = DiffComputation.buildSnapshotDiffLines(
            original: original,
            current: current
        )

        #expect(lines.map(\.text) == [
            " alpha",
            "-beta",
            "+BETA",
            " gamma",
            "+delta",
        ])
        #expect(lines.map(\.oldLineNumber) == [1, 2, nil, 3, nil])
        #expect(lines.map(\.newLineNumber) == [1, nil, 2, 3, 4])
    }

    @Test("full-file edit diff renders an addition with surrounding context")
    func fullFileEditDiffRendersAdditionWithContext() {
        let hunk = PreviewFile.EditHunk(
            oldString: "alpha\nbeta",
            newString: "alpha\n// inserted comment\nbeta"
        )
        let current = "alpha\n// inserted comment\nbeta\n"
        let lines = DiffComputation.buildFullFileEditDiffLines(
            currentContent: current,
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            " alpha",
            "+// inserted comment",
            " beta",
        ])
    }

    @Test("unified diff parser tracks gutter line numbers from hunk header")
    func unifiedDiffParserTracksLineNumbers() {
        let raw = """
        @@ -10,3 +10,3 @@
         keep
        -old
        +new
        """
        let lines = DiffComputation.parseUnifiedDiff(raw)

        #expect(lines.count == 4)
        #expect(lines[0].kind == .hunk)
        #expect(lines[1].kind == .context && lines[1].oldLineNumber == 10 && lines[1].newLineNumber == 10)
        #expect(lines[2].kind == .removed && lines[2].oldLineNumber == 11 && lines[2].newLineNumber == nil)
        #expect(lines[3].kind == .added && lines[3].oldLineNumber == nil && lines[3].newLineNumber == 11)
    }
}
