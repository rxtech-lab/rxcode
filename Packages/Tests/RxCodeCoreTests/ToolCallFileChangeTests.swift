import Testing
@testable import RxCodeCore

@Suite("ToolCall file-change extraction")
struct ToolCallFileChangeTests {

    @Test("Codex app-server fileChange exposes edited path and diff")
    func codexFileChangeDiff() {
        let diff = """
        @@ -1,2 +1,2 @@
        -old
        +new
        """
        let call = ToolCall(
            id: "call-1",
            name: "Edit",
            input: [
                "type": "fileChange",
                "changes": [
                    [
                        "path": "/tmp/example.swift",
                        "diff": .string(diff)
                    ]
                ]
            ]
        )

        #expect(call.editedFilePath == "/tmp/example.swift")
        #expect(call.fileChangeDiffs == [
            ToolCall.FileChangeDiff(path: "/tmp/example.swift", diff: diff)
        ])
    }

    @Test("Codex fileChange diff synthesizes a single old/new hunk")
    func codexFileChangeHunk() {
        let diff = """
        --- a/example.swift
        +++ b/example.swift
        @@ -1,3 +1,3 @@
         keep
        -old line 1
        -old line 2
        +new line 1
        +new line 2
         keep
        """
        let call = ToolCall(
            id: "call-1",
            name: "Edit",
            input: [
                "type": "fileChange",
                "changes": [
                    [
                        "path": "/tmp/example.swift",
                        "diff": .string(diff)
                    ]
                ]
            ]
        )

        let diffs = call.fileChangeDiffs
        #expect(diffs.count == 1)
        let hunk = diffs[0].hunk
        #expect(hunk.oldString == "old line 1\nold line 2")
        #expect(hunk.newString == "new line 1\nnew line 2")
    }
}
