import Foundation

/// Application Support directory scoped by the running bundle identifier.
/// Production (`com.idealapp.RxCode`) keeps the `RxCode` directory.
/// The organization-signed app retains the previous production data directory.
/// Any other bundle id (e.g. a dev build at `com.idealapp.RxCode.dev`) maps to
/// `RxCode.<suffix>` so alternate builds never share state with production.
public enum AppSupport {
    public static var isUnitTesting: Bool {
        #if DEBUG
        if isScreenshotCapture { return true }
        #endif
        let environment = ProcessInfo.processInfo.environment
        return environment["RXCODE_UNIT_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
    }

    public static var isTestProcess: Bool {
        isUnitTesting || ProcessInfo.processInfo.environment["RXCODE_UI_TESTING"] == "1"
    }

    public static let bundleScopedURL: URL = {
        #if DEBUG
        if isScreenshotCapture {
            return FileManager.default.temporaryDirectory.appendingPathComponent("RxCodeMarketingCapture", isDirectory: true)
        }
        #endif
        if let override = ProcessInfo.processInfo.environment["RXCODE_APP_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if AppSupport.isUnitTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("RxCodeUnitTests-\(UUID().uuidString)", isDirectory: true)
        }

        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let target = root.appendingPathComponent(directoryName, isDirectory: true)
        migrateLegacyClarcDirectoryIfNeeded(root: root, target: target)
        return target
    }()

    /// Only a separately identified debug app can open the fictional marketing workspace.
    public static var isScreenshotCapture: Bool {
        #if DEBUG
        Bundle.main.bundleIdentifier == "com.rxlab.RxCode.screenshots"
        #else
        false
        #endif
    }

    public static let personalWorkspaceID = "personal"

    public static func workspaceScopedURL(id: String) -> URL {
        if id == personalWorkspaceID {
            return bundleScopedURL
        }
        return bundleScopedURL
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private static var directoryName: String {
        directoryName(for: Bundle.main.bundleIdentifier ?? "com.idealapp.RxCode")
    }

    static func directoryName(for bundleID: String) -> String {
        if bundleID == "app.rxlab.flowcy.code" { return "RxCode.RxCode" }
        if bundleID == "com.idealapp.RxCode" { return "RxCode" }
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        return "RxCode.\(suffix)"
    }

    private static var legacyDirectoryName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.idealapp.RxCode"
        if bundleID == "app.rxlab.flowcy.code" { return "Clarc.RxCode" }
        if bundleID == "com.idealapp.RxCode" { return "Clarc" }
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        return "Clarc.\(suffix)"
    }

    /// Copy preferences once, before creating services that read standard defaults.
    /// Keep the old domain intact so an existing installation remains usable.
    public static func migrateSigningPreferencesIfNeeded(
        defaults: UserDefaults = .standard,
        bundleID: String? = Bundle.main.bundleIdentifier,
        legacyDomain: String = "com.rxlab.RxCode",
        destinationDomain: String = "app.rxlab.flowcy.code"
    ) {
        guard bundleID == "app.rxlab.flowcy.code" else { return }
        let marker = "rxlabSigningPreferencesMigrated"
        guard !defaults.bool(forKey: marker) else { return }
        let current = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        let previous = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        for (key, value) in previous where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
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
