import Foundation

public enum XcodeAction: String, Codable, Sendable, CaseIterable, Hashable {
    case build
    case run
    case test
    case clean
}

public struct XcodeRunConfig: Codable, Sendable, Hashable {
    /// File name (relative to project root) of the `.xcodeproj` or
    /// `.xcworkspace` to drive `xcodebuild`.
    public var container: String
    public var isWorkspace: Bool
    public var scheme: String
    public var configuration: String
    public var action: XcodeAction
    /// Optional `-destination` argument. Empty string omits the flag.
    public var destination: String

    public init(
        container: String = "",
        isWorkspace: Bool = false,
        scheme: String = "",
        configuration: String = "Debug",
        action: XcodeAction = .run,
        destination: String = ""
    ) {
        self.container = container
        self.isWorkspace = isWorkspace
        self.scheme = scheme
        self.configuration = configuration
        self.action = action
        self.destination = destination
    }
}
