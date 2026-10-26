import Testing
@testable import RxCodeCore

struct ComputerUsePresentationTests {
    @Test func recognizedTools() {
        for name in ["computer", "computer_use", "computer_call", "mcp__cua_repl__js", "mcp__computer_use__click", "cua_repl.js"] {
            #expect(ComputerUsePresentation.recognizes(name))
        }
        for name in ["Bash", "mcp__github__computer", "search_computer", "mcpToolCall"] {
            #expect(!ComputerUsePresentation.recognizes(name))
        }
    }

    @Test func summariesPreferHumanReadableTitles() {
        #expect(ComputerUsePresentation.summary(name: "mcp__cua_repl__js", input: [
            "title": .string("Open Settings"), "code": .string("private script")
        ]) == "Computer use — Open Settings")
        #expect(ComputerUsePresentation.summary(name: "computer", input: [
            "action": .object(["type": .string("left_click")])
        ]) == "Computer use — left click")
        #expect(ComputerUsePresentation.summary(name: "computer", input: [:]) == "Computer use")
        #expect(ComputerUsePresentation.summary(name: "Bash", input: [:]) == nil)
    }
}
