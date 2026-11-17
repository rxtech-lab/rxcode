import Foundation
import Testing
@testable import RxCodeCore

@Suite("Composable pet widgets")
struct PetWidgetSchemaTests {
    @Test("Compact indicators accept emoji and sentences and preserve live bindings")
    func compactIndicator() throws {
        for text in ["🌱", "Working", "Checking the latest build while you work."] {
            let spec = JSONUISpec(root: "status", elements: ["status": .init(type: "Text", props: ["text": .string(text)])])
            try PetWidgetSchema.validate(spec)
            #expect(PetWidgetSchema.indicatorText(spec, runningTasks: 0, runningSessions: 0) == text)
        }
        let live = JSONUISpec(root: "status", elements: ["status": .init(type: "Badge", props: ["text": .object(["$ide": .string("running_tasks")])])])
        #expect(PetWidgetSchema.indicatorText(live, runningTasks: 3, runningSessions: 1) == "3")
        #expect(PetWidgetSchema.indicatorText(live, runningTasks: 0, runningSessions: 1) == "0")
    }

    @Test("The AI composes arbitrary meaning and layout from native primitives")
    func arbitraryComposition() throws {
        let spec = JSONUISpec(root: "layout", elements: [
            "layout": .init(type: "Stack", props: ["direction": .string("horizontal"), "gap": .string("small")], children: ["label", "value"]),
            "label": .init(type: "Text", props: ["text": .string("Reviewing the release notes")]),
            "value": .init(type: "Badge", props: ["text": .string("Draft")])
        ])
        try PetWidgetSchema.validate(spec)
        #expect(spec.textLines.contains("Reviewing the release notes"))
        #expect(!spec.elements.keys.contains("status"))
    }

    @Test("Live IDE bindings resolve from current observable data without freezing counts")
    func liveBindings() throws {
        let spec = JSONUISpec(root: "count", elements: ["count": .init(type: "Stat", props: ["label": .string("Active board tasks"), "value": .object(["$ide": .string("running_tasks")])])])
        try PetWidgetSchema.validate(spec)
        #expect(PetWidgetSchema.resolved(spec, runningTasks: 3, runningSessions: 5).elements["count"]?.props["value"] == .number(3))
        #expect(PetWidgetSchema.resolved(spec, runningTasks: 0, runningSessions: 1).elements["count"]?.props["value"] == .number(0))
        #expect(spec.elements["count"]?.props["value"]?["$ide"] == .string("running_tasks"))
    }

    @Test("Invalid graphs, executable controls, unbounded content and unsupported props are rejected")
    func invalidSpecs() {
        let specs = [
            JSONUISpec(root: "missing", elements: [:]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Button", props: ["label": .string("Run")])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Text", props: ["text": .string(String(repeating: "x", count: 181))])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Text", props: ["text": .object(["html": .string("script")])])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Grid", props: ["columns": .number(1.5)])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Text", props: ["text": .string("Hello"), "onAppear": .string("execute")])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Stat", props: ["value": .object(["$ide": .string("imaginary")])])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Stack", children: ["x"])]),
            JSONUISpec(root: "x", elements: ["x": .init(type: "Text"), "unreachable": .init(type: "Text")])
        ]
        for spec in specs { #expect(throws: PetWidgetSchema.ValidationError.self) { try PetWidgetSchema.validate(spec) } }
    }

    @Test("Every backend discovers the presentation, desktop input, widget and music tools")
    func toolDiscovery() {
        let expected: Set<String> = ["ide__pet_show_image", "ide__pet_click", "ide__pet_scroll", "ide__pet_focus_window", "ide__pet_type_text", "ide__pet_status", "ide__pet_music"]
        for provider in [AgentProvider.codex, .claudeCode, .acp, .localAgent] {
            #expect(expected.isSubset(of: Set(IDEToolRegistry.tools(for: provider.staticCapabilities).map(\.name))))
        }
        let ui = IDEToolRegistry.allTools.first { $0.name == "ide__show_ui" }
        #expect(ui?.inputSchema["properties"]?["pet_presentation"]?["enum"]?.arrayValue == [.string("popover"), .string("bubble")])
    }

    @Test("All agent providers expose device-volume actions and bounded inputs")
    func musicVolumeContract() throws {
        for provider in [AgentProvider.codex, .claudeCode, .acp, .localAgent] {
            let tool = try #require(IDEToolRegistry.tools(for: provider.staticCapabilities).first { $0.name == "ide__pet_music" })
            let properties = try #require(tool.inputSchema["properties"])
            for action in ["volume", "set_volume", "increase_volume", "decrease_volume"] {
                #expect(properties["action"]?["enum"]?.arrayValue?.contains(.string(action)) == true)
            }
            #expect(properties["volume"]?["minimum"] == .number(0))
            #expect(properties["volume"]?["maximum"] == .number(100))
            #expect(properties["amount"]?["maximum"] == .number(100))
        }
    }
}
