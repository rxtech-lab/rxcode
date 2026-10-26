import Foundation
import Testing
@testable import RxCodeCore

@Suite("JSON UI specs")
struct JSONUISpecTests {
    private static let comparison: JSONValue = [
        "title": "Cache strategies",
        "spec": [
            "root": "root",
            "elements": [
                "root": ["type": "Stack", "props": ["gap": "medium"], "children": ["intro", "tabs"]],
                "intro": ["type": "Callout", "props": ["tone": "tip", "text": "Pick by read/write ratio."]],
                "tabs": ["type": "Tabs", "props": ["tabs": ["Table", "Steps"]], "children": ["table", "steps"]],
                "table": ["type": "Table", "props": [
                    "columns": [["key": "name", "label": "Strategy"], ["key": "ms", "label": "Latency", "format": "number", "total": true]],
                    "rows": [["cells": ["name": "Write-through", "ms": 12]], ["cells": ["name": "Write-back", "ms": ["value": 3, "detail": "async"]]]],
                ]],
                "steps": ["type": "Steps", "props": ["items": [["title": "Measure", "status": "done"], ["title": "Switch", "detail": "Behind a flag"]]]],
            ],
        ],
    ]

    @Test("A valid spec parses, validates and flattens to text")
    func validSpec() throws {
        let payload = JSONUITool.payload(from: Self.comparison.objectValue ?? [:])
        let spec = try #require(payload.spec)
        #expect(payload.title == "Cache strategies")
        #expect(spec.issues.isEmpty)
        #expect(spec.textLines == [
            "Pick by read/write ratio.", "[Table]", "Strategy | Latency", "Write-through | 12", "Write-back | 3",
            "[Steps]", "1. Measure", "2. Switch — Behind a flag",
        ])
        #expect(JSONUITable(try #require(spec.elements["table"])).total(of: JSONUITable(spec.elements["table"]!).columns[1]) == 15)
        #expect(try JSONUITool.result(for: Self.comparison).contains("\"Cache strategies\" is displayed"))
    }

    @Test("A spec serialized as a string is accepted")
    func stringifiedSpec() throws {
        let spec = Self.comparison["spec"]!
        let text = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        #expect(JSONUITool.payload(from: ["spec": .string(text)]).spec?.elements.count == 5)
    }

    @Test("Broken trees, unknown types and leaf children are reported")
    func invalidSpec() throws {
        let spec = JSONUISpec(root: "root", elements: [
            "root": JSONUIElement(type: "Stack", children: ["a", "a", "missing"]),
            "a": JSONUIElement(type: "Text", props: ["text": "hi"], children: ["root"]),
            "b": JSONUIElement(type: "Carousel"),
        ])
        let issues = spec.issues
        #expect(issues.contains { $0.contains("unknown type \"Carousel\"") })
        #expect(issues.contains { $0.hasPrefix("elements.a: only") })
        #expect(issues.contains { $0.contains("\"a\" is used more than once") })
        #expect(issues.contains { $0.contains("unknown element \"missing\"") })
        #expect(issues.contains { $0.contains("\"root\" is used more than once") })
        #expect(throws: JSONUIToolError.self) {
            try JSONUITool.result(for: .object(["spec": .string("not json")]))
        }
    }

    @Test("Tool names match across runtimes and the IDE exposes the tool")
    func toolNames() {
        #expect(JSONUITool.matches("mcp__rxcode-ide__ide__show_ui"))
        #expect(JSONUITool.matches("mcp__rxcode__ide__show_ui"))
        #expect(JSONUITool.matches("show_ui"))
        #expect(!JSONUITool.matches("mcp__other__show_ui_later"))
        #expect(IDEToolRegistry.tools(for: []).contains { $0.name == "ide__show_ui" })
    }

    @Test("Calls saved under a generic MCP name are recognized by their input")
    func genericCodexCalls() throws {
        let spec = Self.comparison["spec"]!
        #expect(JSONUITool.matches(ToolCall(id: "1", name: "mcp__rxcode-ide", input: ["title": "Demo", "spec": spec])))
        let item = ToolCall(id: "2", name: "mcpToolCall", input: ["tool": "ide__show_ui", "arguments": ["spec": spec]])
        #expect(JSONUITool.matches(item))
        #expect(JSONUITool.payload(from: item.input).spec?.elements.count == 5)
        #expect(!JSONUITool.matches(ToolCall(id: "3", name: "mcp__rxcode-ide", input: ["query": "tasks"])))
        #expect(!JSONUITool.matches(ToolCall(id: "4", name: "mcp__other", input: ["spec": spec])))
    }

    @Test("Values format by their format")
    func formatting() {
        #expect(JSONUIFormat.text(.string("n/a"), format: "money") == "n/a")
        #expect(JSONUIFormat.text(nil, format: nil) == "—")
        #expect(JSONUIFormat.text(.number(0.25), format: "duration") == "250 ms")
        #expect(JSONUIFormat.text(.number(42), format: "percent").contains("42"))
    }

    @Test("Presentation defaults to inline and accepts dialog")
    func presentation() throws {
        let spec = Self.comparison["spec"]!
        #expect(JSONUITool.payload(from: ["spec": spec]).presentation == .inline)
        let dialog: JSONValue = ["title": "Report", "spec": spec, "presentation": "dialog"]
        #expect(try JSONUITool.validated(dialog).payload.presentation == .dialog)
        #expect(try JSONUITool.result(for: dialog).contains("in a dialog"))
        #expect(try !JSONUITool.result(for: dialog, supportsDialog: false).contains("in a dialog"))
        #expect(throws: JSONUIToolError.self) {
            try JSONUITool.result(for: ["spec": spec, "presentation": "popover"])
        }
    }

    @Test("Confirmation requests read labels and require a title")
    func confirmation() throws {
        let request = try ConfirmationTool.request(from: ["title": " Delete 3 files? ", "confirm_label": "Delete", "destructive": true])
        #expect(request == ConfirmationTool.Request(title: "Delete 3 files?", confirmLabel: "Delete", isDestructive: true))
        #expect(throws: ConfirmationToolError.self) { try ConfirmationTool.request(from: ["message": "No title"]) }
        #expect(ConfirmationTool.result(confirmed: false)["confirmed"]?.boolValue == false)
        #expect(IDEToolRegistry.tools(for: []).contains { $0.name == ConfirmationTool.ideName })
    }
}
