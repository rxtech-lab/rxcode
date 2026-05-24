import Testing
import RxCodeCore
@testable import RxCodeChatKit

@Suite("FileDiffView diff building")
@MainActor
struct FileDiffViewTests {
    @Test("full-file edit diff includes unchanged context")
    func fullFileEditDiffIncludesContext() {
        let hunk = PreviewFile.EditHunk(oldString: "two", newString: "TWO")
        let lines = FileDiffView.buildFullFileEditDiffLines(
            currentContent: "one\nTWO\nthree\n",
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            " one",
            "-two",
            "+TWO",
            " three",
        ])
    }

    @Test("full-file edit diff reconstructs multiple edits in reverse order")
    func fullFileEditDiffReconstructsMultipleEdits() {
        let hunks = [
            PreviewFile.EditHunk(oldString: "alpha", newString: "ALPHA"),
            PreviewFile.EditHunk(oldString: "gamma", newString: "GAMMA"),
        ]
        let lines = FileDiffView.buildFullFileEditDiffLines(
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
        let lines = FileDiffView.buildFullFileEditDiffLines(
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
        // Pure deletion: hunk removes a line, replacing it with empty.
        // The current file no longer contains the removed line, so we can't
        // anchor it inline — it's surfaced as an orphan change at the top.
        let hunk = PreviewFile.EditHunk(
            oldString: "        guard Self.hasExplicitMemoryIntent(userMessage) else { return }",
            newString: ""
        )
        let current = "        let userMessage = lastUserMessageText(in: messages)\n        let finalResponse = lastAssistantResponseText(in: messages)\n        let sourceMessageId = nil\n"
        let lines = FileDiffView.buildFullFileEditDiffLines(
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
        // Write tool surfaces as a single hunk with empty oldString and the
        // entire file as newString. Reverse-applied this clears the
        // reconstructed pre-edit, so every current line shows as `+`.
        let content = "line one\nline two\nline three\n"
        let hunk = PreviewFile.EditHunk(oldString: "", newString: content)
        let lines = FileDiffView.buildFullFileEditDiffLines(
            currentContent: content,
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            "+line one",
            "+line two",
            "+line three",
        ])
    }

    @Test("snapshot diff renders exact changes between pre and post snapshots")
    func snapshotDiffRendersExactChanges() {
        // The new snapshot-based path doesn't reverse-apply hunks — it just
        // diffs two full-file strings. Every line that differs shows up as
        // -/+, every shared line as context. No orphan headers.
        let original = "alpha\nbeta\ngamma\n"
        let current = "alpha\nBETA\ngamma\ndelta\n"
        let lines = FileDiffView.buildSnapshotDiffLines(
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
        // Old line numbers should track positions in the original snapshot.
        #expect(lines.map(\.oldLineNumber) == [1, 2, nil, 3, nil])
        // New line numbers should track positions in the current file.
        #expect(lines.map(\.newLineNumber) == [1, nil, 2, 3, 4])
    }

    @Test("full-file edit diff renders an addition with surrounding context")
    func fullFileEditDiffRendersAdditionWithContext() {
        // Realistic Edit hunk shape: oldString and newString both include the
        // anchor line so the replacement is unique. The diff shows the new
        // line inserted between alpha and beta.
        let hunk = PreviewFile.EditHunk(
            oldString: "alpha\nbeta",
            newString: "alpha\n// inserted comment\nbeta"
        )
        let current = "alpha\n// inserted comment\nbeta\n"
        let lines = FileDiffView.buildFullFileEditDiffLines(
            currentContent: current,
            hunks: [hunk]
        )

        #expect(lines.map(\.text) == [
            " alpha",
            "+// inserted comment",
            " beta",
        ])
    }
}
