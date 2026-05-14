import Foundation

public struct InteractiveTerminalState: Identifiable, Sendable {
    public static let toolName = "interactive_terminal"

    public let id = UUID()
    public let title: String
    public let executable: String
    public let arguments: [String]
    public var environment: [String]?
    public var currentDirectory: String?
    public var initialCommand: String?
    public var reportToChat: Bool

    public init(
        title: String,
        executable: String,
        arguments: [String],
        environment: [String]? = nil,
        currentDirectory: String? = nil,
        initialCommand: String? = nil,
        reportToChat: Bool = true
    ) {
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.initialCommand = initialCommand
        self.reportToChat = reportToChat
    }
}
