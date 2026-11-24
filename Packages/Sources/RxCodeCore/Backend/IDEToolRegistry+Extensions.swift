import Foundation

extension IDEToolRegistry {
    static let extensionDevelopmentTools: [IDETool] = {
        let name: JSONValue = .object([
            "type": .string("string"),
            "maxLength": .number(48),
            "pattern": .string("^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"),
            "description": .string("Project-local extension name. Use the same name to reload and test it."),
        ])
        func tool(_ name: String, _ description: String, _ fields: [String: JSONValue], required: [String]) -> IDETool {
            IDETool(name: name, description: description, visibility: .alwaysIDEOnly, inputSchema: .object([
                "type": .string("object"),
                "properties": .object(fields),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ]))
        }
        return [
            tool("ide__list_extensions", "List enabled workspace extensions discovered by macOS.", [:], required: []),
            tool("ide__create_extension",
                 "Create an editable native workspace service extension in this project chat's checkout. Edit its generated Swift implementation and README.md, optionally add a square PNG named icon.png next to them, then call ide__reload_extension.",
                 ["name": name], required: ["name"]),
            tool("ide__reload_extension",
                 "Build and hot load the named workspace service extension, or reload it after editing its Swift source. README.md and icon.png in the extension folder are packaged with it and shown in Settings. RxCode asks the user to confirm signing and opens the macOS enablement sheet in chat if needed. After loading succeeds, call ide__test_extension.",
                 ["name": name, "signing_identity": .object([
                    "type": .string("string"),
                    "description": .string("Optional local signing identity for the development build."),
                 ])], required: ["name"]),
            tool("ide__test_extension",
                 "Send input to the loaded workspace service extension and return its actual response. To test source edits, reload the extension first.",
                 ["name": name, "input": .object(["type": .string("string")])], required: ["name", "input"]),
        ]
    }()
}
