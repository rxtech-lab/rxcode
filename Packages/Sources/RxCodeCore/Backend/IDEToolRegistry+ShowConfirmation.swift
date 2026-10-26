import Foundation

extension IDEToolRegistry {
    static let showConfirmationTool = IDETool(
        name: ConfirmationTool.ideName,
        description: ConfirmationTool.description,
        visibility: .alwaysIDEOnly,
        inputSchema: ConfirmationTool.inputSchema
    )
}
