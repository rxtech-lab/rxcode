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

    // MARK: - Edge cases pulled from real chat threads

    /// Case 1 (AppState+MobileSync.swift on fix/mobilesync-fanout-perf):
    /// thread recorded a large pure-deletion edit (199 lines removed); git diff
    /// matches. Snapshot-pair captured a race where `originalContent` and
    /// `modifiedContent` ended up identical (both post-edit). Sidebar fell
    /// back to hunk counts and showed `-200 +1`, but the body short-circuited
    /// to "No changes" because the snapshot-pair diff was empty and the
    /// legacy disk-read fallback returned unconditionally with empty lines.
    /// `buildThreadEditDiff` must fall back to the hunk-based diff so the
    /// body still renders the recorded edit.
    @Test("thread edit diff falls back to hunks when snapshot pair collapses")
    func threadEditDiffFallsBackWhenSnapshotPairCollapses() {
        // Mirrors the AppState+MobileSync.swift case: one hunk replaces a
        // 200-line block with 1 line. Snapshots collapsed identical so the
        // pair diff would produce only context lines — the helper must
        // recognise that as "no real change" and render the hunk instead.
        let postEdit = "line A\nline B\nline C\n"
        let deletedBlock = (1...200).map { "deleted line \($0)" }.joined(separator: "\n")
        let hunk = PreviewFile.EditHunk(oldString: deletedBlock, newString: "kept")

        let lines = DiffComputation.buildThreadEditDiff(
            originalContent: postEdit,
            modifiedContent: postEdit,
            hunks: [hunk]
        )

        let removed = lines.filter { $0.kind == .removed }.count
        let added = lines.filter { $0.kind == .added }.count
        let context = lines.filter { $0.kind == .context }.count
        #expect(removed == 200)
        #expect(added == 1)
        #expect(context == 0, "Collapsed-pair fallback should render the hunk, not all-context lines from the equal snapshots")
    }

    @Test("thread edit diff treats an all-context snapshot pair as no real change")
    func threadEditDiffTreatsAllContextAsNoChange() {
        // Even a non-empty buildSnapshotDiffLines result counts as "no
        // change" when every line is context — that's the symptom from the
        // production AppState+MobileSync.swift bug where the body listed the
        // file but the change counter said "No changes".
        let snapshot = "alpha\nbeta\ngamma\n"
        let snapshotLines = DiffComputation.buildSnapshotDiffLines(original: snapshot, current: snapshot)
        #expect(!snapshotLines.isEmpty)
        #expect(snapshotLines.allSatisfy { $0.kind == .context })

        let hunk = PreviewFile.EditHunk(oldString: "removed", newString: "")
        let lines = DiffComputation.buildThreadEditDiff(
            originalContent: snapshot,
            modifiedContent: snapshot,
            hunks: [hunk]
        )
        #expect(lines.map(\.text) == ["-removed"])
    }

    /// Case 2 (new-file `Write` row on fix/mobilesync-fanout-perf): the
    /// thread recorded a `Write` tool call creating a file with ~201 lines —
    /// the orange "+" sidebar badge in ThreadChangesSheet that fires on
    /// `containsWrite`. Snapshot capture lost its race so `originalContent`
    /// and `modifiedContent` both ended up populated with the post-write
    /// content (instead of `originalContent` being `nil` / `""`). The
    /// sidebar's `turnStat` saw `snapshotStat == (0, 0)` from the collapsed
    /// pair, fell back to `hunkStat` and counted `newString` newlines —
    /// reporting `+201` — but the detail view rendered only context lines
    /// because `buildSnapshotDiffLines(same, same)` is pure-context. Result
    /// on screen: row shows `+201`, body shows zero added rows. The diff
    /// computation must fall back to the recorded `("", newString)` hunk so
    /// the body matches the sidebar's `+201`, with pure-create gutter
    /// numbering 1…N on the new side and a `nil` old gutter throughout.
    /// Counts/content here are real-shape (a 201-line file write) rather
    /// than literal bytes from the branch — git remains the source of
    /// truth for the *branch* this scenario was captured on, the test
    /// fixes the *contract* the helper must honour for any such row.
    @Test("thread edit diff falls back to hunks for new-file Write when snapshot pair collapses")
    func threadEditDiffFallsBackForNewFileWriteWhenSnapshotPairCollapses() {
        let writtenContent = (1...201).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let hunk = PreviewFile.EditHunk(oldString: "", newString: writtenContent)

        let lines = DiffComputation.buildThreadEditDiff(
            originalContent: writtenContent,
            modifiedContent: writtenContent,
            hunks: [hunk]
        )

        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        let context = lines.filter { $0.kind == .context }.count
        #expect(added == 201)
        #expect(removed == 0)
        #expect(
            context == 0,
            "Collapsed-pair fallback for a new-file Write must render the hunk, not 201 context lines from the equal snapshots"
        )
        // Pure-create numbering: new gutter 1…201, old gutter empty.
        #expect(lines.compactMap(\.newLineNumber) == Array(1...201))
        #expect(lines.allSatisfy { $0.oldLineNumber == nil })
    }

    @Test("thread edit diff prefers snapshot pair when both differ")
    func threadEditDiffPrefersSnapshotPair() {
        let hunk = PreviewFile.EditHunk(oldString: "two", newString: "TWO")
        let lines = DiffComputation.buildThreadEditDiff(
            originalContent: "one\ntwo\nthree\n",
            modifiedContent: "one\nTWO\nthree\n",
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [" one", "-two", "+TWO", " three"])
        #expect(lines.map(\.oldLineNumber) == [1, 2, nil, 3])
        #expect(lines.map(\.newLineNumber) == [1, nil, 2, 3])
    }

    @Test("thread edit diff falls back to hunks when modifiedContent is missing")
    func threadEditDiffFallsBackWhenModifiedContentMissing() {
        let hunk = PreviewFile.EditHunk(oldString: "foo", newString: "FOO")
        let lines = DiffComputation.buildThreadEditDiff(
            originalContent: "foo\n",
            modifiedContent: nil,
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == ["-foo", "+FOO"])
    }

    @Test("thread edit diff returns empty when there is no snapshot pair and no hunks")
    func threadEditDiffReturnsEmptyWhenNothingRecorded() {
        let lines = DiffComputation.buildThreadEditDiff(
            originalContent: nil,
            modifiedContent: nil,
            hunks: []
        )

        #expect(lines.isEmpty)
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
