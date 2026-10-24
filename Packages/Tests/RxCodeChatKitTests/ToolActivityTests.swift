import Foundation
import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
struct ToolActivityTests {
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
        #expect(labels.contains("3 tool calls"))
        #expect(labels.contains("1 running · 1 succeeded · 1 failed"))
        #expect(!labels.contains("Read"))
    }
}
