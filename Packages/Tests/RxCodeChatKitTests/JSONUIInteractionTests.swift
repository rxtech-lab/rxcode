import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("JSON UI local interactions")
struct JSONUIInteractionTests {
    @Test func renderedButtonDispatchesItsDeclaredAction() throws {
        let state = JSONUIInteraction(spec: spec)
        let control = JSONUIControl(id: "open", element: .init(type: "Button", props: [
            "label": "Edit", "action": ["type": "present", "target": "sheet"],
        ]), interaction: state)
        try control.inspect().find(ViewType.Button.self).tap()
        #expect(state.presented == "sheet")
    }

    private var spec: JSONUISpec {
        JSONUISpec(root: "root", elements: [
            "root": .init(type: "Stack", children: ["name", "enabled"]),
            "name": .init(type: "TextField", props: ["required": true]),
            "enabled": .init(type: "Toggle", props: ["value": true]),
            "sheet": .init(type: "Sheet", children: ["description"]),
            "description": .init(type: "Text", props: ["text": "Edit item"]),
            "alert": .init(type: "Alert", props: ["title": "Confirm"]),
        ])
    }

    @Test func stateIsSharedWithinOneViewAndIsolatedBetweenViews() {
        let first = JSONUIInteraction(spec: spec)
        let second = JSONUIInteraction(spec: spec)
        first.perform(["type": "set", "name": "name", "value": "Draft"])
        #expect(first.values["name"] == "Draft")
        #expect(second.values["name"] == "")
        first.perform(["type": "reset"])
        #expect(first.values == spec.initialValues)
        #expect(first.notice == "Form reset.")
    }

    @Test func requiredFieldsBlockSubmissionAndHostReceivesCurrentValues() {
        var submissions: [[String: JSONValue]] = []
        let state = JSONUIInteraction(spec: spec) { submissions.append($0) }
        state.perform(["type": "submit"])
        #expect(submissions.isEmpty)
        #expect(state.notice?.contains("required") == true)
        state.perform(["type": "set", "name": "name", "value": "Ready"])
        state.perform(["type": "submit"])
        #expect(submissions == [["name": "Ready", "enabled": true]])
    }

    @Test func standaloneSubmissionAccuratelyReportsLocalCapture() {
        let state = JSONUIInteraction(spec: spec)
        state.values["name"] = "Local only"
        state.perform(["type": "submit"])
        #expect(state.notice == "Form captured locally. No data was sent.")
    }

    @Test func presentationsDoNotStackAndDismissAllowsReopening() {
        let state = JSONUIInteraction(spec: spec)
        state.perform(["type": "present", "target": "sheet"])
        #expect(state.presented == "sheet")
        state.perform(["type": "present", "target": "alert"])
        #expect(state.presented == "sheet")
        state.perform(["type": "dismiss"])
        state.perform(["type": "present", "target": "alert"])
        #expect(state.presented == "alert")
        state.perform(["type": "dismiss"])
        state.perform(["type": "present", "target": "name"])
        #expect(state.presented == nil)
    }

    @Test func separateFormsSubmitAndResetIndependently() {
        var spec = spec
        spec.elements["form"] = .init(type: "Form", children: ["enabled"])
        spec.elements["root"]?.children = ["name", "form"]
        var submitted: [String: JSONValue] = [:]
        let state = JSONUIInteraction(spec: spec) { submitted = $0 }
        state.values["name"] = "Keep this draft"
        state.values["enabled"] = false
        state.perform(["type": "submit"], formID: "form")
        #expect(submitted == ["enabled": false])
        state.perform(["type": "reset", "target": "form"])
        #expect(state.values["enabled"] == true)
        #expect(state.values["name"] == "Keep this draft")
        state.values["name"] = ""
        state.perform(["type": "submit", "target": "form"])
        #expect(state.notice == "Form submitted to the host.")
    }
}
