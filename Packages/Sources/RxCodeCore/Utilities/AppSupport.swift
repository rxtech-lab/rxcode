import Foundation

/// Application Support directory scoped by the running bundle identifier.
/// Production (`com.idealapp.RxCode`) keeps the `RxCode` directory.
/// Any other bundle id (e.g. a dev build at `com.idealapp.RxCode.dev`) maps to
/// `RxCode.<suffix>` so alternate builds never share state with production.
public enum AppSupport {
    public static let bundleScopedURL: URL = {
        if let override = ProcessInfo.processInfo.environment["RXCODE_APP_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let target = root.appendingPathComponent(directoryName, isDirectory: true)
        migrateLegacyClarcDirectoryIfNeeded(root: root, target: target)
        return target
    }()

    private static var directoryName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.idealapp.RxCode"
        if bundleID == "com.idealapp.RxCode" { return "RxCode" }
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        return "RxCode.\(suffix)"
    }

    private static var legacyDirectoryName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.idealapp.RxCode"
        if bundleID == "com.idealapp.RxCode" { return "Clarc" }
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        return "Clarc.\(suffix)"
    }

    // One-shot migration: rename the pre-rebrand "Clarc" Application Support
    // directory to "RxCode" so existing users keep their projects, sessions,
    // and settings after upgrading.
    private static func migrateLegacyClarcDirectoryIfNeeded(root: URL, target: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return }
        let legacy = root.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: target)
    }
}
