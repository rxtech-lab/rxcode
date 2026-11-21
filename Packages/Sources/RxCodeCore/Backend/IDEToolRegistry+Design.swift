import Foundation

extension IDEToolRegistry {
    public static let designTools: [IDETool] = {
        let string = JSONValue.object(["type": .string("string")])
        let fraction = JSONValue.object(["type": .string("number"), "minimum": .number(0), "exclusiveMaximum": .number(1)])
        let tab = ["tab_id": string], target = ["target_id": string]
        let point = ["target_id": string, "x": fraction, "y": fraction]
        func tool(_ name: String, _ help: String, _ fields: [String: JSONValue] = [:], _ required: [String] = []) -> IDETool {
            IDETool(name: "ide__" + name, description: help, visibility: .alwaysIDEOnly, inputSchema: .object([
                "type": .string("object"), "properties": .object(fields), "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false)
            ]))
        }
        return [
            tool("browser_tabs", "List tabs and their IDs, titles, addresses, and selection in this workspace window."),
            tool("browser_open", "Open an HTTP(S) or localhost URL in a new workspace browser tab.", ["url": string], ["url"]),
            tool("browser_select_tab", "Show the specified browser tab.", tab, ["tab_id"]),
            tool("browser_close_tab", "Close the specified browser tab.", tab, ["tab_id"]),
            tool("browser_navigate", "Navigate a browser tab to a URL or go back, forward, or reload.", [
                "tab_id": string, "url": string, "action": .object(["type": .string("string"), "enum": .array(["open","back","forward","reload"].map(JSONValue.string))])
            ], ["tab_id", "action"]),
            tool("browser_inspect", "List visible interactive HTML elements and their selectors.", tab, ["tab_id"]),
            tool("browser_click", "Click an HTML element using a selector from browser_inspect or a Design refinement.", ["tab_id": string, "selector": string], ["tab_id", "selector"]),
            tool("browser_type", "Set the text in an editable HTML element.", ["tab_id": string, "selector": string, "text": string], ["tab_id", "selector", "text"]),
            tool("browser_screenshot", "Return a screenshot of this browser tab as an image.", tab, ["tab_id"]),
            tool("simulator_list", "List booted simulators for iOS or Android emulators.", ["platform": .object(["type": .string("string"), "enum": .array([.string("iOS"), .string("Android")])])], ["platform"]),
            tool("simulator_screenshot", "Return an image of the selected booted simulator.", target, ["target_id"]),
            tool("simulator_inspect", "Identify a simulator accessibility element at normalized x/y from the screenshot’s top left.", point, ["target_id", "x", "y"]),
            tool("simulator_tap", "Tap the simulator at normalized x/y from the screenshot’s top left.", point, ["target_id", "x", "y"]),
            tool("simulator_type", "Type into the focused simulator control.", ["target_id": string, "text": string], ["target_id","text"]),
            tool("app_list_windows", "List visible Mac app windows and their exact target IDs."),
            tool("app_screenshot", "Return an image of the specified Mac window.", target, ["target_id"]),
            tool("app_inspect", "Describe the Mac accessibility element at normalized x/y from the window’s top left.", point, ["target_id","x","y"]),
            tool("app_click", "Click the specified Mac window at normalized x/y.", point, ["target_id","x","y"]),
            tool("app_type", "Type into the focused text control of the specified Mac window.", ["target_id": string, "text": string], ["target_id","text"]),
            tool("swiftui_preview", "Render a SwiftUI preview through Xcode MCP, display it in the inspector, and return the screenshot.", [
                "path": string, "preview_index": .object(["type": .string("integer"), "minimum": .number(0)]), "xcode_tab": string
            ], ["path"]),
            tool("document_preview", "Show a project PDF, Markdown, or other document in the Preview tab of the right inspector.", ["path": string], ["path"])
        ]
    }()
}
