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
    /// Structured destination chosen via the toolbar picker. When set, the
    /// run script uses `selectedDestination.xcodebuildArgument` and branches
    /// the launcher path on `selectedDestination.kind`.
    public var selectedDestination: XcodeDestination?
    /// Legacy free-text `-destination` override. Older profiles on disk
    /// stored their destination here. Still honored when
    /// `selectedDestination` is nil so we don't break those.
    public var destination: String

    public init(
        container: String = "",
        isWorkspace: Bool = false,
        scheme: String = "",
        configuration: String = "Debug",
        action: XcodeAction = .run,
        selectedDestination: XcodeDestination? = nil,
        destination: String = ""
    ) {
        self.container = container
        self.isWorkspace = isWorkspace
        self.scheme = scheme
        self.configuration = configuration
        self.action = action
        self.selectedDestination = selectedDestination
        self.destination = destination
    }

    /// Resolves the value (if any) that should be passed to
    /// `xcodebuild -destination`. Prefers the structured picker selection.
    public var resolvedDestinationArgument: String? {
        if let selectedDestination {
            return selectedDestination.xcodebuildArgument
        }
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case container, isWorkspace, scheme, configuration, action
        case selectedDestination, destination
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? ""
        isWorkspace = try c.decodeIfPresent(Bool.self, forKey: .isWorkspace) ?? false
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        configuration = try c.decodeIfPresent(String.self, forKey: .configuration) ?? "Debug"
        action = try c.decodeIfPresent(XcodeAction.self, forKey: .action) ?? .run
        selectedDestination = try c.decodeIfPresent(XcodeDestination.self, forKey: .selectedDestination)
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
    }
}
