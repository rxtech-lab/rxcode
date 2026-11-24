import Foundation
import RxCodeCore

/// The plugin API that this RxCode build exposes to workspace extensions.
///
/// The API 2.0 preview is opt-in until distributed first-party packages pass the release gate.
nonisolated enum ExtensionPluginAPI {
    /// Bump when the host/extension contract (bridge messages, entry points, packaging) changes.
    static let releaseVersion = ExtensionManifest.apiVersion

    static var v2Enabled: Bool { ExtensionFeatures.isV2Enabled }

    static var legacyVersion: String {
        #if DEBUG
        "main"
        #else
        "1.0"
        #endif
    }

    static var version: String { v2Enabled ? releaseVersion : legacyVersion }

    /// Info.plist key that records the plugin API an extension was built against.
    static let infoPlistKey = "RxCodePluginAPIVersion"

    struct Capability: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    static var capabilities: [Capability] { legacyCapabilities + (v2Enabled ? [
        Capability(id: "manifest", title: "Extension manifest", detail: "Declares permissions and native scenes in extension.json.", symbol: "puzzlepiece.extension")
    ] : []) }

    private static let legacyCapabilities: [Capability] = [
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
