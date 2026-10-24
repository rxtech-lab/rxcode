import Foundation

extension IDEToolRegistry {
    static let showUITool = IDETool(
        name: JSONUITool.ideName,
        description: JSONUITool.description,
        visibility: .alwaysIDEOnly,
        inputSchema: JSONUITool.inputSchema
    )
}
