import Foundation
import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("ShellDetectedChangesView")
struct ShellDetectedChangesViewTests {

    @Test("Standalone ToolResultView displays detected shell file changes and inline diff immediately")
    func standaloneToolResultShowsDetectedShellChanges() throws {
        var bash = ToolCall(
            id: "bash-1",
            name: "Bash",
            input: ["command": .string("python3 -c \"open('Sources/Worker.swift','w').write('...')\"")],
            result: "",
            isError: false
        )
        bash.setDetectedShellFileChanges([
            DetectedShellFileChange(
                path: "/repo/Sources/Worker.swift",
                kind: .created,
                addedLines: 2,
                removedLines: 0,
                diff: "@@ -0,0 +1,2 @@\n+struct Worker {\n+}",
                isAmbiguous: false
            )
        ])

        let view = ToolResultView(toolCall: bash, isMessageStreaming: false)
        let inspected = try view.inspect()
        let labels = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(!inspected.findAll(ShellDetectedChangesView.self).isEmpty)
        #expect(labels.contains("Worker.swift"))
        #expect(labels.contains("New"))
        #expect(labels.contains("+2"))
        #expect(labels.contains { $0.contains("+struct Worker {") })
    }

    #if os(macOS)
    @Test("Collapsed desktop tool group folds detected shell changes with its tool calls")
    func collapsedDesktopGroupHidesDetectedShellChanges() throws {
        var scriptTool = ToolCall(
            id: "exec-1",
            name: "exec_command",
            input: ["cmd": .array([.string("bash"), .string("-lc"), .string("sed -i '' 's/a/b/' App.swift")])],
            result: "done"
        )
        scriptTool.setDetectedShellFileChanges([
            DetectedShellFileChange(
                path: "/repo/App.swift",
                kind: .modified,
                addedLines: 1,
                removedLines: 1,
                diff: "@@ -1,1 +1,1 @@\n-let a = 1\n+let b = 1",
                isAmbiguous: true
            )
        ])

        let view = ChatTransientToolSummaryView(
            tools: [
                ToolCall(id: "read-1", name: "read_file", result: "contents"),
                scriptTool,
            ],
            isStreaming: false
        )
        let inspected = try view.inspect()
        let labels = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(inspected.findAll(ToolResultView.self).isEmpty)
        #expect(inspected.findAll(ShellDetectedChangesView.self).isEmpty)
        #expect(!labels.contains("App.swift"))
        #expect(!labels.contains("Concurrent"))
        #expect(labels.contains("2 tool calls"))

    }
    #endif

    @Test("ToolActivityGroupView folds detected changes and preserves them in detail views")
    func toolActivityGroupAndDetailViewHandleDetectedShellChanges() throws {
        var tool = ToolCall(
            id: "acp-exec-1",
            name: "run_command",
            input: [
                "command": .string("rm OldFile.swift"),
                ToolCall.acpKindInputKey: .string("execute"),
            ],
            result: ""
        )
        tool.setDetectedShellFileChanges([
            DetectedShellFileChange(
                path: "/repo/OldFile.swift",
                kind: .deleted,
                addedLines: 0,
                removedLines: 4,
                diff: "@@ -1,4 +0,0 @@\n-line1\n-line2\n-line3\n-line4"
            )
        ])

        let groupView = ToolActivityGroupView(tools: [tool], isStreaming: false)
        let inspectedGroup = try groupView.inspect()
        let groupLabels = inspectedGroup.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(inspectedGroup.findAll(ShellDetectedChangesView.self).isEmpty)
        #expect(!groupLabels.contains("OldFile.swift"))
        #expect(!groupLabels.contains("Deleted"))
        #expect(!groupLabels.contains("−4"))

        let detailView = ToolActivityDetailView(tool: tool, isStreaming: false)
        let detailLabels = try detailView.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(detailLabels.contains("Detected File Changes"))
        #expect(detailLabels.contains("OldFile.swift"))
        #expect(detailLabels.contains("Deleted"))
        #expect(detailLabels.contains("−4"))
        #expect(!detailLabels.contains { $0.contains(ToolCall.detectedFileChangesInputKey) })
        #expect(!detailLabels.contains { $0.contains(ToolCall.acpKindInputKey) })

        let sheet = ToolCallDetailSheet(toolCall: tool)
        let sheetLabels = try sheet.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(sheetLabels.contains("Detected File Changes"))
        #expect(!sheetLabels.contains { $0.contains(ToolCall.detectedFileChangesInputKey) })
    }

    @Test("aggregatedChanges merges sequential edits to the same file in a tool group")
    func aggregatedChangesMergesSameFileEdits() {
        var first = ToolCall(id: "t1", name: "Bash")
        first.setDetectedShellFileChanges([
            DetectedShellFileChange(
                path: "/repo/A.swift",
                kind: .created,
                addedLines: 3,
                removedLines: 0,
                diff: "+one\n+two\n+three"
            )
        ])
        var second = ToolCall(id: "t2", name: "Bash")
        second.setDetectedShellFileChanges([
            DetectedShellFileChange(
                path: "/repo/A.swift",
                kind: .modified,
                addedLines: 1,
                removedLines: 1,
                diff: "-two\n+TWO",
                isAmbiguous: true
            ),
            DetectedShellFileChange(
                path: "/repo/B.swift",
                kind: .modified,
                addedLines: 2,
                removedLines: 0,
                diff: "+x\n+y"
            ),
        ])

        let merged = ShellDetectedChangesView.aggregatedChanges(from: [first, second])
        #expect(merged.map(\.fileName) == ["A.swift", "B.swift"])
        #expect(merged[0].kind == .created)
        #expect(merged[0].addedLines == 4)
        #expect(merged[0].removedLines == 1)
        #expect(merged[0].isAmbiguous == true)
    }
}
