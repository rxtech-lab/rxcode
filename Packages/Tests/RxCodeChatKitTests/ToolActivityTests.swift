import Foundation
import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
struct ToolActivityTests {
    @Test func providerToolCallsGroupDuringStreamingAndAfterCompletion() {
        let tools = [
            ToolCall(id: "codex", name: "exec_command"),
            ToolCall(id: "acp", name: "read_file"),
            ToolCall(id: "mcp", name: "mcp__server__search")
        ]
        for streaming in [true, false] {
            let messages = tools.map { tool in
                var message = ChatMessage(role: .assistant, content: "")
                message.blocks = [.toolCall(tool)]
                message.isStreaming = streaming
                return message
            }
            let groups = chatMessageGroups(messages)
            #expect(groups.count == 1)
            #expect(groups.first?.isTransientGroup == true)
            #expect(groups.first?.id == messages.first?.id)
            #expect(groups.first?.messages.last?.blocks.last?.toolCall?.name == tools.last?.name)

            var combined = messages[0]
            combined.blocks = tools.map { .toolCall($0) }
            #expect(chatMessageGroups([combined]).first?.isTransientGroup == true)

            let separator = ChatMessage(role: .assistant, content: "Explanation")
            #expect(chatMessageGroups([messages[0], separator, messages[1]]).count == 3)

            let whitespace = ChatMessage(role: .assistant, blocks: [.text("\n\n")])
            let bridged = chatMessageGroups([messages[0], whitespace, messages[1]])
            #expect(bridged.count == 1)
            #expect(bridged.first?.isTransientGroup == true)
        }
    }

    @Test func narrationWithToolCallJoinsFollowingToolGroup() {
        for streaming in [true, false] {
            // Mirrors a Codex turn: "I'll check…" + Bash, then tool-only messages.
            let narrated = ChatMessage(role: .assistant, blocks: [
                .text("I'll check the icon file."),
                .toolCall(ToolCall(id: "bash-1", name: "Bash"))
            ], isStreaming: streaming, duration: 3)
            let followups = ["reasoning", "Edit", "Bash", "reasoning", "Bash"].enumerated().map { index, name in
                ChatMessage(role: .assistant, blocks: [.toolCall(ToolCall(id: "t\(index)", name: name))],
                            isStreaming: streaming)
            }
            let groups = chatMessageGroups([narrated] + followups)
            #expect(groups.count == 2)
            #expect(groups.first?.id == narrated.id)
            #expect(groups.first?.isTransientGroup == false)
            #expect(groups.first?.messages.first?.blocks.compactMap(\.text) == ["I'll check the icon file."])
            #expect(groups.first?.messages.first?.duration == 3)
            #expect(groups.last?.isTransientGroup == true)
            #expect(groups.last?.messages.flatMap(\.toolCalls).count == 6)
            #expect(Set(groups.map(\.id)).count == groups.count)
        }
    }

    @Test func reasoningRowsStayInsideTheToolGroup() throws {
        for streaming in [true, false] {
            let names = ["exec_command", "reasoning", "exec_command", "reasoning", "reasoning", "read_file"]
            let messages = names.enumerated().map { index, name in
                ChatMessage(
                    role: .assistant,
                    blocks: [.toolCall(ToolCall(
                        id: "call-\(index)",
                        name: name,
                        result: streaming ? nil : "Completed"
                    ))],
                    isStreaming: streaming
                )
            }
            let groups = chatMessageGroups(messages)
            #expect(groups.count == 1)
            #expect(groups.first?.isTransientGroup == true)
            #expect(groups.first?.messages.flatMap(\.toolCalls).map(\.name) == names)

            #if os(macOS)
            let view = ChatTransientGroupSummaryView(messages: messages)
            let inspected = try view.inspect()
            let labels = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            #expect(labels.contains("read_file"))
            #expect(labels.contains("6 tool calls"))
            #expect(!labels.contains("reasoning"))
            #expect(inspected.findAll(ToolResultView.self).isEmpty)
            #endif
        }
    }

    @Test func interactiveToolsRemainOutsideCollapsedGroups() {
        for name in ["AskUserQuestion", "ExitPlanMode", "exit_plan_mode",
                     "ImageGeneration", ReviewCountdownCard.toolName] {
            #expect(!chatCanGroupTool(ToolCall(id: name, name: name)))
        }
        #expect(chatCanGroupTool(ToolCall(id: "edit", name: "apply_patch")))
    }

    #if os(macOS)
    private struct StreamingHost: View {
        let bridge: ChatBridge
        let window = WindowState()

        var body: some View {
            StreamingMessageView(onStructureChanged: {})
                .environment(bridge)
                .environment(window)
        }
    }

    @Test func streamingResponseCombinesCompletedAndActiveTools() throws {
        let bridge = ChatBridge()
        let completed = ChatMessage(role: .assistant, blocks: [
            .toolCall(ToolCall(id: "bash", name: "Bash", result: "Done"))
        ])
        var active = ChatMessage(role: .assistant, blocks: (0..<12).map {
            .toolCall(ToolCall(id: "reasoning-\($0)", name: "reasoning"))
        }, isStreaming: true)
        bridge.messages = [ChatMessage(role: .user, content: "Run tools"), completed, active]
        let view = StreamingHost(bridge: bridge)
        let summaries = try view.inspect().findAll(ChatTransientGroupSummaryView.self)
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first).actualView()
        #expect(summary.messages.map(\.id) == [completed.id, active.id])
        let labels = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.contains("13 tool calls"))
        #expect(!labels.contains("1 tool call"))

        // A narration message must still separate tool runs in the active response.
        let narration = ChatMessage(role: .assistant, content: "Checking the result")
        bridge.messages.insert(narration, at: 2)
        #expect(try view.inspect().findAll(ChatTransientGroupSummaryView.self).count == 2)

        // Completing the response preserves the same group in the settled list.
        active.isStreaming = false
        let groups = chatMessageGroups([completed, active])
        #expect(groups.count == 1)
        #expect(groups.first?.id == summary.messages.first?.id)
    }

    @Test func desktopGroupShowsLatestToolAndStartsCollapsed() throws {
        let view = ChatTransientToolSummaryView(tools: [
            ToolCall(id: "a", name: "exec_command", result: "ok"),
            ToolCall(id: "b", name: "read_file")
        ], isStreaming: true)
        let inspected = try view.inspect()
        let labels = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.contains("read_file"))
        #expect(labels.contains("2 tool calls"))
        #expect(!labels.contains("exec_command"))
        #expect(inspected.findAll(ToolResultView.self).isEmpty)
    }
    #endif

    @Test func statusesIncludeEmptySuccessAndResultlessFailure() {
        #expect(ToolActivityStatus(tool: ToolCall(id: "1", name: "read"), isStreaming: true) == .running)
        #expect(ToolActivityStatus(tool: ToolCall(id: "1", name: "read"), isStreaming: false) == .interrupted)
        #expect(ToolActivityStatus(tool: ToolCall(id: "1", name: "read", result: ""), isStreaming: true) == .succeeded)
        #expect(ToolActivityStatus(tool: ToolCall(id: "1", name: "read", isError: true), isStreaming: true) == .failed)
    }

    @Test func savedResultsMatchByIDAndKeepOrphans() throws {
        let messages = try JSONDecoder().decode([JSONValue].self, from: Data("""
        [
          {"toolCalls":[{"id":"a","name":"read","arguments":{"path":"a.md"}},{"id":"b","name":"read","arguments":{}}]},
          {"toolResults":[{"id":"b","name":"read","result":{"isError":true}},{"id":"a","name":"read","result":""}]},
          {"toolResults":[{"id":"orphan","name":"bash","result":"output"}]}
        ]
        """.utf8))
        let groups = SavedSessionToolCalls.groups(in: messages)
        #expect(groups.map(\.count) == [2, 0, 1])
        #expect(groups[0][0].result == "")
        #expect(groups[0][0].input["path"]?.stringValue == "a.md")
        #expect(groups[0][1].isError)
        #expect(groups[2][0].result == "output")
    }

    @Test func longResultsAndEmbeddedFencesRemainIntact() {
        let long = String(repeating: "A long result with **Markdown** and ```code```\n", count: 2000)
        #expect(ToolActivityFormatting.resultMarkdown(long) == long)
        let encoded = ToolActivityFormatting.jsonMarkdown(.object(["body": .string(long)]))
        #expect(encoded.hasPrefix("````json\n"))
        #expect(encoded.hasSuffix("\n````"))
        #expect(encoded.contains("**Markdown**"))
    }

    @Test func structuredTextResultsRenderAsMarkdownWithRawDataAvailable() {
        let raw = "{\"content\":[{\"type\":\"text\",\"text\":\"# Output\\n\\nLine two\"}],\"metadata\":42}"
        #expect(ToolActivityFormatting.resultMarkdown(raw) == "# Output\n\nLine two")
        #expect(ToolActivityFormatting.rawResultMarkdown(raw).contains("metadata"))
    }

    @Test func paginatedJSONKeepsEveryCharacterAndBalancesFences() {
        let result = ToolActivityFormatting.jsonMarkdown(.array((1...100).map {
            .object(["title": .string("Task \($0)"), "body": .string("Details with ```embedded fences```.")])
        }))
        let pages = ToolActivityFormatting.pages(result)
        #expect(pages.count > 1)
        #expect(pages.map(\.source).joined() == result)
        for page in pages {
            #expect(page.source.count <= 4000)
            #expect(page.markdown.hasPrefix("````json\n"))
            #expect(page.markdown.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("````"))
            #expect(page.markdown.split(separator: "\n").count <= 35)
        }
    }

    @Test func minifiedAndUnicodeResultsAreBoundedWithoutLosingContent() {
        let result = String(repeating: "👩🏽‍💻abc", count: 5000)
        let pages = ToolActivityFormatting.pages(result)
        #expect(pages.count > 1)
        #expect(pages.allSatisfy { $0.source.count <= 4000 })
        #expect(pages.map(\.source).joined() == result)
    }

    @Test func paginationHandlesTildeFencesAndEmptyOutput() {
        let result = "~~~json\n" + String(repeating: "[1, 2, 3]\n", count: 100) + "~~~\nAfter code."
        let pages = ToolActivityFormatting.pages(result)
        #expect(pages.map(\.source).joined() == result)
        #expect(pages.dropLast().allSatisfy { $0.markdown.hasSuffix("\n~~~") })
        #expect(pages.last?.markdown.hasSuffix("After code.") == true)
        #expect(ToolActivityFormatting.pages("").first?.markdown == "The tool returned an empty result.")
    }

    @Test func groupStartsCollapsedWithMixedStates() throws {
        let view = ToolActivityGroupView(tools: [
            ToolCall(id: "a", name: "Read", result: "ok"),
            ToolCall(id: "b", name: "Bash", isError: true),
            ToolCall(id: "c", name: "Search")
        ], isStreaming: true)
        let labels = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.contains("Search"))
        #expect(labels.contains("3 tool calls · 1 running · 1 succeeded · 1 failed"))
        #expect(!labels.contains("Read"))
    }

    @Test func toolNamesAndArgumentsBecomeReadableLabels() {
        #expect(ToolActivityPresentation.title(for: "mcp__rxcode-ide__ide__get_projects") == "Get projects")
        #expect(ToolActivityPresentation.title(for: "list_issues") == "List issues")
        #expect(ToolActivityPresentation.source(for: "mcp__github__search") == "github")
        #expect(ToolActivityPresentation.source(for: "list_issues") == nil)
        #expect(ToolActivityPresentation.preview(for: ["limit": 5, "query": "open bugs\nmore"]) == "open bugs")
        #expect(ToolActivityPresentation.preview(for: ["limit": 5]) == nil)
    }

    @Test func interactiveViewsRenderInlineOutsideTheGroup() throws {
        let view = ToolActivityGroupView(tools: [
            ToolCall(id: "a", name: "Read", result: "ok"),
            ToolCall(id: "ui", name: "show_ui", input: [
                "title": "Plan",
                "spec": ["root": "s", "elements": ["s": ["type": "Steps", "props": ["items": [["title": "Measure"]]]]]],
            ], result: "ok"),
        ])
        let labels = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.contains("1 tool call · 1 succeeded"))
        #expect(labels.contains("Plan"))
        #expect(labels.contains("Measure"))
    }
}
