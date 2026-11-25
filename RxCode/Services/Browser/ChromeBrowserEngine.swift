import AppKit
import Foundation
import RxCodeCore

/// Rendering engine for the workspace in-app browser.
nonisolated enum BrowserEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case webkit
    case chrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webkit: String(localized: "WebKit (Built-in)")
        case .chrome: String(localized: "Chrome")
        }
    }

    var shortTitle: String {
        switch self {
        case .webkit: String(localized: "WebKit")
        case .chrome: String(localized: "Chrome")
        }
    }

    var summary: String {
        switch self {
        case .webkit:
            String(localized: "Built-in macOS WebKit engine. Fast, native, and requires no extra download.")
        case .chrome:
            String(localized: "Uses an optional downloaded Chrome for Testing runtime (or system Google Chrome) without bundling Chromium into RxCode.")
        }
    }

    var systemImage: String {
        switch self {
        case .webkit: "safari"
        case .chrome: "globe"
        }
    }
}

/// Finds, downloads, updates, and removes an optional Chrome for Testing runtime
/// in Application Support so Chromium is never bundled inside RxCode.app.
nonisolated enum ChromeBrowserRuntimeInstaller {
    enum Source: String, Codable, Equatable, Sendable {
        case managed
        case system
    }

    struct Runtime: Equatable, Sendable {
        let executablePath: String
        let version: String
        let source: Source

        var displaySource: String {
            switch source {
            case .managed: String(localized: "Downloaded (Chrome for Testing)")
            case .system: String(localized: "System Google Chrome")
            }
        }
    }

    struct ReleaseInfo: Equatable, Sendable {
        let version: String
        let downloadURL: URL
    }

    enum InstallError: LocalizedError, Equatable {
        case noAsset
        case binaryNotFound
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAsset:
                String(localized: "No macOS Chrome for Testing release was found.")
            case .binaryNotFound:
                String(localized: "The downloaded Chrome archive did not contain the Chrome executable.")
            case .extractFailed(let detail):
                String(localized: "Could not extract Chrome: \(detail)")
            }
        }
    }

    static let versionsEndpoint = URL(
        string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
    )!

    static let systemChromeAppPath = "/Applications/Google Chrome.app"
    static let systemChromeExecutablePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    static var platformName: String {
        #if arch(arm64)
        "mac-arm64"
        #else
        "mac-x64"
        #endif
    }

    static func managedRoot(_ appSupport: URL = AppSupport.bundleScopedURL) -> URL {
        appSupport.appending(path: "BrowserEngine/chrome-for-testing", directoryHint: .isDirectory)
    }

    static func profileDirectory(_ appSupport: URL = AppSupport.bundleScopedURL) -> URL {
        appSupport.appending(path: "BrowserEngine/chrome-profile", directoryHint: .isDirectory)
    }

    /// Locates RxCode's downloaded Chrome for Testing binary, picking the newest installed version.
    static func locateManaged(appSupport: URL = AppSupport.bundleScopedURL) -> Runtime? {
        let root = managedRoot(appSupport)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return nil
        }
        let sorted = versions.sorted { compareVersions($0, $1) == .orderedDescending }
        for version in sorted where !version.hasPrefix(".") {
            let versionDir = root.appending(path: version, directoryHint: .isDirectory)
            if let binary = findExecutable(in: versionDir) {
                return Runtime(executablePath: binary.path, version: version, source: .managed)
            }
        }
        return nil
    }

    /// Locates Google Chrome installed on the system, if present.
    static func locateSystem(executablePath: String = systemChromeExecutablePath) -> Runtime? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return nil }
        let plistURL = URL(filePath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Info.plist")
        let version = (NSDictionary(contentsOf: plistURL)?["CFBundleShortVersionString"] as? String) ?? "system"
        return Runtime(executablePath: executablePath, version: version, source: .system)
    }

    /// Returns the preferred Chrome runtime: downloaded Chrome for Testing first, then optional system Chrome.
    static func locate(appSupport: URL = AppSupport.bundleScopedURL, allowSystemFallback: Bool = true) -> Runtime? {
        if let managed = locateManaged(appSupport: appSupport) {
            return managed
        }
        return allowSystemFallback ? locateSystem() : nil
    }

    /// Queries Google's official Chrome for Testing channel manifest for the latest Stable build.
    static func latestRelease(
        platform: String = platformName,
        session: URLSession = .shared
    ) async throws -> ReleaseInfo {
        var request = URLRequest(url: versionsEndpoint)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LocalModelDownloader.DownloadError.http(http.statusCode)
        }
        return try parseLatestRelease(from: data, platform: platform)
    }

    static func parseLatestRelease(from data: Data, platform: String = platformName) throws -> ReleaseInfo {
        struct Manifest: Decodable {
            struct Channel: Decodable {
                struct Downloads: Decodable {
                    struct Artifact: Decodable {
                        let platform: String
                        let url: String
                    }
                    let chrome: [Artifact]?
                }
                let version: String
                let downloads: Downloads
            }
            let channels: [String: Channel]
        }

        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let stable = manifest.channels["Stable"],
              let match = stable.downloads.chrome?.first(where: { $0.platform == platform }),
              let url = URL(string: match.url) else {
            throw InstallError.noAsset
        }
        return ReleaseInfo(version: stable.version, downloadURL: url)
    }

    /// Downloads and unpacks the latest Stable Chrome for Testing build into Application Support.
    static func install(
        appSupport: URL = AppSupport.bundleScopedURL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Runtime {
        let release = try await latestRelease()
        let root = managedRoot(appSupport)
        let destination = root.appending(path: release.version, directoryHint: .isDirectory)
        let staging = root.appending(path: ".staging-\(release.version)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let archive = root.appending(path: "\(release.version).zip")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: archive)
        }

        _ = try await LocalModelDownloader().download(release.downloadURL, to: archive, onProgress: onProgress)
        // Signal switch from downloading bytes to extracting the archive.
        onProgress(0, 0)

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archive.path, staging.path]
            let pipe = Pipe()
            ditto.standardError = pipe
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw InstallError.extractFailed(message.isEmpty ? "exit \(ditto.terminationStatus)" : message)
            }

            let xattr = Process()
            xattr.executableURL = URL(filePath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", staging.path]
            try? xattr.run()
            xattr.waitUntilExit()
        }.value

        guard findExecutable(in: staging) != nil else {
            throw InstallError.binaryNotFound
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)

        guard let binary = findExecutable(in: destination) else {
            throw InstallError.binaryNotFound
        }

        // Remove older downloaded versions so only one managed copy uses disk space.
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            where entry != release.version && !entry.hasPrefix(".") {
            try? FileManager.default.removeItem(at: root.appending(path: entry))
        }

        return Runtime(executablePath: binary.path, version: release.version, source: .managed)
    }

    static func removeManaged(appSupport: URL = AppSupport.bundleScopedURL) throws {
        let root = managedRoot(appSupport)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Compares dotted numeric Chrome version strings such as `158.0.8127.88`.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        guard count > 0 else { return lhs.localizedStandardCompare(rhs) }
        for idx in 0..<count {
            let a = idx < left.count ? left[idx] : 0
            let b = idx < right.count ? right[idx] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compareVersions(candidate, installed) == .orderedDescending
    }

    static func findExecutable(in directory: URL) -> URL? {
        let knownRelativePaths = [
            "chrome-\(platformName)/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        ]
        for relative in knownRelativePaths {
            let candidate = directory.appending(path: relative)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "Google Chrome for Testing",
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

/// Manages the selected in-app browser engine and the optional downloaded Chrome runtime.
@MainActor @Observable
final class BrowserEngineManager {
    static let shared = BrowserEngineManager()

    static let enginePreferenceKey = "inAppBrowserEngine"
    static let useSystemChromeKey = "inAppBrowserUseSystemChrome"

    enum InstallState: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case extracting
        case removing

        var isBusy: Bool { self != .idle }
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case available(String)
        case upToDate
        case failed(String)
    }

    enum StatusBanner: Equatable {
        case working(String)
        case finished(String)
        case failed(String)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appSupport: URL
    @ObservationIgnored private var installTask: Task<Void, Never>?

    var selectedEngine: BrowserEngineKind {
        didSet {
            guard selectedEngine != oldValue else { return }
            defaults.set(selectedEngine.rawValue, forKey: Self.enginePreferenceKey)
            if selectedEngine == .webkit {
                Task { await ChromeBrowserService.shared.stop() }
            }
        }
    }

    var useSystemChromeFallback: Bool {
        didSet {
            guard useSystemChromeFallback != oldValue else { return }
            defaults.set(useSystemChromeFallback, forKey: Self.useSystemChromeKey)
            if !isChromeAvailable, selectedEngine == .chrome {
                selectedEngine = .webkit
            }
        }
    }

    private(set) var managedRuntime: ChromeBrowserRuntimeInstaller.Runtime?
    private(set) var systemRuntime: ChromeBrowserRuntimeInstaller.Runtime?
    private(set) var installState: InstallState = .idle
    private(set) var updateState: UpdateState = .idle
    var statusBanner: StatusBanner?

    var effectiveChromeRuntime: ChromeBrowserRuntimeInstaller.Runtime? {
        managedRuntime ?? (useSystemChromeFallback ? systemRuntime : nil)
    }

    var isChromeAvailable: Bool {
        effectiveChromeRuntime != nil
    }

    /// The engine currently used by workspace browser tabs. Falls back to WebKit if Chrome is unavailable.
    var activeEngine: BrowserEngineKind {
        selectedEngine == .chrome && isChromeAvailable ? .chrome : .webkit
    }

    var summaryLabel: String {
        switch activeEngine {
        case .webkit:
            return BrowserEngineKind.webkit.title
        case .chrome:
            if let runtime = effectiveChromeRuntime {
                return runtime.source == .managed
                    ? String(localized: "Chrome (\(runtime.version))")
                    : String(localized: "System Chrome (\(runtime.version))")
            }
            return BrowserEngineKind.chrome.title
        }
    }

    init(defaults: UserDefaults = .standard, appSupport: URL = AppSupport.bundleScopedURL) {
        self.defaults = defaults
        self.appSupport = appSupport
        let savedEngine = defaults.string(forKey: Self.enginePreferenceKey).flatMap(BrowserEngineKind.init(rawValue:)) ?? .webkit
        let savedFallback = defaults.object(forKey: Self.useSystemChromeKey) as? Bool ?? true
        self.selectedEngine = savedEngine
        self.useSystemChromeFallback = savedFallback
        refreshInstalled()
    }

    func refreshInstalled() {
        managedRuntime = ChromeBrowserRuntimeInstaller.locateManaged(appSupport: appSupport)
        systemRuntime = ChromeBrowserRuntimeInstaller.locateSystem()
    }

    func checkForUpdates() async {
        guard updateState != .checking else { return }
        updateState = .checking
        do {
            let release = try await ChromeBrowserRuntimeInstaller.latestRelease()
            if let installed = managedRuntime {
                if ChromeBrowserRuntimeInstaller.isNewer(release.version, than: installed.version) {
                    updateState = .available(release.version)
                } else {
                    updateState = .upToDate
                }
            } else {
                updateState = .available(release.version)
            }
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    func installOrUpdateChrome(switchAfterInstall: Bool = false) {
        guard !installState.isBusy else { return }
        let updating = managedRuntime != nil
        installState = .downloading(received: 0, total: 0)
        statusBanner = .working(updating ? String(localized: "Updating Chrome runtime…") : String(localized: "Downloading Chrome runtime…"))

        let support = appSupport
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                if updating {
                    await ChromeBrowserService.shared.stop()
                }
                let runtime = try await ChromeBrowserRuntimeInstaller.install(appSupport: support) { received, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if received == 0 && total == 0 {
                            self.installState = .extracting
                            self.statusBanner = .working(String(localized: "Extracting Chrome runtime…"))
                        } else {
                            self.installState = .downloading(received: received, total: total)
                        }
                    }
                }
                self.managedRuntime = runtime
                self.installState = .idle
                self.updateState = .upToDate
                if switchAfterInstall {
                    self.selectedEngine = .chrome
                }
                self.statusBanner = .finished(
                    updating
                        ? String(localized: "Updated Chrome to \(runtime.version)")
                        : String(localized: "Downloaded Chrome \(runtime.version)")
                )
            } catch is CancellationError {
                self.installState = .idle
                self.statusBanner = nil
            } catch LocalModelDownloader.DownloadError.cancelled {
                self.installState = .idle
                self.statusBanner = nil
            } catch {
                self.installState = .idle
                self.statusBanner = .failed(error.localizedDescription)
            }
            self.installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        installState = .idle
        statusBanner = nil
    }

    func uninstallManagedChrome() async {
        guard !installState.isBusy else { return }
        installState = .removing
        statusBanner = .working(String(localized: "Removing Chrome runtime…"))
        await ChromeBrowserService.shared.stop()
        do {
            try ChromeBrowserRuntimeInstaller.removeManaged(appSupport: appSupport)
            refreshInstalled()
            if !isChromeAvailable && selectedEngine == .chrome {
                selectedEngine = .webkit
            }
            installState = .idle
            updateState = .idle
            statusBanner = .finished(String(localized: "Removed downloaded Chrome runtime"))
        } catch {
            installState = .idle
            statusBanner = .failed(error.localizedDescription)
        }
    }
}
