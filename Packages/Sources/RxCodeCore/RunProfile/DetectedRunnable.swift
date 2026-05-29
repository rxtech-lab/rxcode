import Foundation

/// Source of an auto-detected runnable shown in the "+" picker of the Run
/// Configurations dialog (desktop) and the run profile editor (mobile).
public enum RunnableSource: String, Codable, Sendable, Hashable {
    case xcode
    case npm
    case make
}

/// A single auto-detected runnable. Pre-fills either a bash command (npm,
/// make) or a structured Xcode config (when `xcode` is non-nil) when the user
/// picks it from the "+" menu. Not persisted on its own — selecting one
/// materializes a normal `RunProfile`.
///
/// The desktop produces these via `RunProfileDetector`; they are also sent to
/// paired mobile clients over the sync protocol so detection logic stays
/// entirely on the desktop.
public struct DetectedRunnable: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let source: RunnableSource
    public let displayName: String
    public let command: String
    /// Present when `source == .xcode`. The dialog materializes these as
    /// `.xcode`-typed profiles instead of bash configurations.
    public let xcode: XcodeRunConfig?
    /// Present when `source == .make`. The dialog materializes these as
    /// `.make`-typed profiles instead of bash configurations.
    public let make: MakeRunConfig?
    /// Present when `source == .npm`. The dialog materializes these as
    /// `.packageScript`-typed profiles, carrying the detected package manager
    /// and script name.
    public let package: PackageRunConfig?

    public init(
        id: String,
        source: RunnableSource,
        displayName: String,
        command: String,
        xcode: XcodeRunConfig? = nil,
        make: MakeRunConfig? = nil,
        package: PackageRunConfig? = nil
    ) {
        self.id = id
        self.source = source
        self.displayName = displayName
        self.command = command
        self.xcode = xcode
        self.make = make
        self.package = package
    }
}

/// Auto-detected runnables for a project, grouped by source.
public struct DetectedRunnables: Codable, Sendable, Hashable {
    public var xcode: [DetectedRunnable]
    public var npm: [DetectedRunnable]
    public var make: [DetectedRunnable]

    public init(
        xcode: [DetectedRunnable] = [],
        npm: [DetectedRunnable] = [],
        make: [DetectedRunnable] = []
    ) {
        self.xcode = xcode
        self.npm = npm
        self.make = make
    }

    public var isEmpty: Bool { xcode.isEmpty && npm.isEmpty && make.isEmpty }
}
