import Foundation
import Testing
import RxCodeCore

@Suite("JSON UI interaction contracts")
struct JSONUIInteractionTests {
    static let editor = JSONUISpec(root: "open", elements: [
        "open": .init(type: "Button", props: ["label": "Edit", "action": ["type": "present", "target": "sheet"]]),
        "sheet": .init(type: "Sheet", props: ["title": "Edit item"], children: ["form"]),
        "form": .init(type: "Form", children: ["name", "enabled", "priority", "size", "save"]),
        "name": .init(type: "TextField", props: ["label": "Name", "required": true]),
        "enabled": .init(type: "Toggle"),
        "priority": .init(type: "Picker", props: ["options": ["Low", "High"]]),
        "size": .init(type: "Slider", props: ["min": 2, "max": 10]),
        "save": .init(type: "Button", props: ["label": "Save", "action": ["type": "submit"]]),
    ])

    @Test func detachedSheetAndDefaultsAreSupported() throws {
        #expect(Self.editor.issues.isEmpty)
        #expect(Self.editor.initialValues == ["name": "", "enabled": false, "priority": "Low", "size": 2])
        let encoded = try JSONEncoder().encode(Self.editor)
        #expect(try JSONDecoder().decode(JSONUISpec.self, from: encoded) == Self.editor)
        #expect(JSONUITool.inputSchema["properties"]?["spec"]?["properties"]?["elements"]?["additionalProperties"]?["properties"]?["type"]?["enum"]?.arrayValue?.contains("Button") == true)
    }

    @Test func invalidActionsAndTargetsAreRejected() {
        let actions: [JSONValue] = [["type": "execute", "command": "touch file"], ["type": "present", "target": "missing"], ["type": "present", "target": "name"], ["type": "set", "name": "enabled", "value": "yes"], ["type": "set", "name": "size", "value": 20]]
        for action in actions {
            var spec = Self.editor
            spec.elements["open"]?.props["action"] = action
            #expect(!spec.issues.isEmpty)
        }
    }

    @Test func malformedFieldsAreRejected() {
        var spec = Self.editor
        spec.elements["name"]?.props["name"] = "enabled"
        spec.elements["enabled"]?.props["value"] = "true"
        spec.elements["priority"]?.props["value"] = "Unknown"
        spec.elements["size"]?.props["step"] = 0
        #expect(spec.issues.contains { $0.contains("unique") })
        #expect(spec.issues.contains { $0.contains("wrong input type") })
        #expect(spec.issues.contains { $0.contains("one of options") })
        #expect(spec.issues.contains { $0.contains("positive step") })
    }

    @Test func detachedTreesAreValidatedAndDepthIsBounded() {
        var spec = Self.editor
        spec.elements["form"]?.children.append("missing")
        #expect(spec.issues.contains { $0.contains("unknown element") })
        spec.elements["form"]?.children = ["sheet"]
        #expect(spec.issues.contains { $0.contains("acyclic") })
        var elements: [String: JSONUIElement] = [:]
        for index in 0...JSONUICatalog.maxDepth {
            elements[String(index)] = .init(type: "Stack", children: index < JSONUICatalog.maxDepth ? [String(index + 1)] : [])
        }
        #expect(!JSONUISpec(root: "0", elements: elements).issues.isEmpty)
    }
}
