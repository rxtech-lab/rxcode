import Foundation

/// The plugin API that this RxCode build exposes to workspace extensions.
///
/// Release builds report `releaseVersion`. Debug builds track the unreleased API on `main`,
/// so extensions built by a Debug host are flagged when loaded by a release host and vice versa.
nonisolated enum ExtensionPluginAPI {
    /// Bump when the host/extension contract (bridge messages, entry points, packaging) changes.
    static let releaseVersion = "1.0"

    #if DEBUG
    static let version = "main"
    #else
    static let version = releaseVersion
    #endif

    /// Info.plist key that records the plugin API an extension was built against.
    static let infoPlistKey = "RxCodePluginAPIVersion"

    struct Capability: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    static let capabilities: [Capability] = [
        Capability(
            id: "workspace-service",
            title: "Workspace Service",
            detail: "Headless XPC service at the workspace-service extension point.",
            symbol: "gearshape.2"
        ),
        Capability(
            id: "workspace",
            title: "Workspace Contribution",
            detail: "Contributor with UI at the workspace extension point.",
            symbol: "rectangle.on.rectangle"
        ),
        Capability(
            id: "run-test",
            title: "WorkspaceExtension.runTest(_:)",
            detail: "Text request handler called by ide__test_extension.",
            symbol: "text.bubble"
        ),
        Capability(
            id: "package-resources",
            title: "README.md and icon.png",
            detail: "Packaged from the extension folder and shown in Settings.",
            symbol: "doc.richtext"
        ),
    ]

    enum Compatibility: Equatable, Sendable {
        case compatible
        case undeclared
        case mismatch(String)

        var isCompatible: Bool { self == .compatible }
    }

    static func compatibility(of extensionVersion: String?, host: String = version) -> Compatibility {
        guard let declared = extensionVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !declared.isEmpty else {
            return .undeclared
        }
        return declared == host ? .compatible : .mismatch(declared)
    }

    static func warning(for compatibility: Compatibility, host: String = version) -> String? {
        switch compatibility {
        case .compatible:
            return nil
        case .undeclared:
            return "This extension does not declare a plugin API version. It may not work with plugin API \(host)."
        case .mismatch(let declared):
            return "Built for plugin API \(declared), but this RxCode build supports \(host). Rebuild the extension to avoid incompatibilities."
        }
    }
}
