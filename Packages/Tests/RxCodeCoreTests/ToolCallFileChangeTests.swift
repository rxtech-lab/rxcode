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
}
