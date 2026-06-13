import SwiftUI
import AppKit
import RxCodeCore

// MARK: - ExternalEditor

struct ExternalEditor: Identifiable, Hashable {
    let id: String
    let displayName: String
    let bundleId: String?
    let cliCommand: String?

    static let all: [ExternalEditor] = [
        ExternalEditor(id: "vscode",        displayName: "VS Code",        bundleId: "com.microsoft.VSCode",      cliCommand: "code"),
        ExternalEditor(id: "cursor",        displayName: "Cursor",         bundleId: "com.todesktop.230313mzl4w4u92", cliCommand: "cursor"),
        ExternalEditor(id: "zed",           displayName: "Zed",            bundleId: "dev.zed.Zed",               cliCommand: "zed"),
        ExternalEditor(id: "antigravity",   displayName: "Antigravity",    bundleId: "com.google.antigravity",    cliCommand: nil),
        ExternalEditor(id: "finder",        displayName: "Finder",         bundleId: "com.apple.finder",          cliCommand: nil),
        ExternalEditor(id: "terminal",      displayName: "Terminal",       bundleId: "com.apple.Terminal",        cliCommand: nil),
        ExternalEditor(id: "warp",          displayName: "Warp",           bundleId: "dev.warp.Warp-Stable",      cliCommand: nil),
        ExternalEditor(id: "xcode",         displayName: "Xcode",          bundleId: "com.apple.dt.Xcode",        cliCommand: nil),
        ExternalEditor(id: "androidstudio", displayName: "Android Studio", bundleId: "com.google.android.studio", cliCommand: nil),
        ExternalEditor(id: "pycharm",       displayName: "PyCharm",        bundleId: "com.jetbrains.pycharm",     cliCommand: nil),
        ExternalEditor(id: "webstorm",      displayName: "WebStorm",       bundleId: "com.jetbrains.WebStorm",    cliCommand: nil),
    ]

    var systemSymbol: String {
        switch id {
        case "vscode", "cursor", "zed", "xcode", "androidstudio", "pycharm", "webstorm", "antigravity":
            return "chevron.left.forwardslash.chevron.right"
        case "finder":
            return "folder"
        case "terminal", "warp":
            return "apple.terminal"
        default:
            return "app"
        }
    }
}

// MARK: - ExternalEditorService

@MainActor
@Observable
final class ExternalEditorService {
    static let shared = ExternalEditorService()

    private init() {}

    /// Editors detected as installed. Read this from SwiftUI bodies — it is
    /// populated asynchronously by `detectIfNeeded()`. Never compute detection
    /// inline in a view body: `isInstalled` can spawn a `which` subprocess and
    /// block the main thread with `waitUntilExit`, which spins a nested run loop
    /// and lets queued work (e.g. a scroll Task) reenter SwiftUI mid-update —
    /// previously crashing in `ScrollViewProxy.scrollTo`.
    private(set) var detectedEditors: [ExternalEditor] = []
    private var hasDetected = false

    /// Detects installed editors off the main thread, once per launch. Safe to
    /// call repeatedly (e.g. from `.task`); only the first call does the work.
    func detectIfNeeded() {
        guard !hasDetected else { return }
        hasDetected = true
        Task.detached(priority: .utility) {
            let detected = ExternalEditor.all.filter { Self.isInstalled($0) }
            await MainActor.run { self.detectedEditors = detected }
        }
    }

    nonisolated static func isInstalled(_ editor: ExternalEditor) -> Bool {
        if let bundleId = editor.bundleId,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
            return true
        }
        if let cli = editor.cliCommand, which(cli) != nil {
            return true
        }
        return false
    }

    func open(_ editor: ExternalEditor, path: String) {
        // Prefer CLI when present — better project-mode handling for code/cursor/zed
        if let cli = editor.cliCommand, let cliPath = Self.which(cli) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [path]
            try? process.run()
            return
        }
        // Fallback: open the bundle with the path as an argument
        if let bundleId = editor.bundleId,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = [path]
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)
            return
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Cached GitHub web URLs for projects whose remote had to be detected via
    /// `git` (keyed by project path). Populated off the main thread by
    /// `detectRepoURLIfNeeded(for:)`.
    private(set) var detectedRepoURLs: [String: URL] = [:]
    private var repoDetectionInFlight: Set<String> = []

    /// GitHub web URL for a project. Read this from SwiftUI bodies — it never
    /// blocks: it uses the already-known `project.gitHubRepo`, falling back to
    /// the async-detected cache. Detecting an unknown remote runs `git` and
    /// blocks with `waitUntilExit`, so that work lives in
    /// `detectRepoURLIfNeeded(for:)`, never in a view body.
    func gitHubURL(for project: Project) -> URL? {
        if let ownerRepo = project.gitHubRepo {
            return gitHubWebURL(forOwnerRepo: ownerRepo)
        }
        return detectedRepoURLs[project.path]
    }

    /// Detects a project's GitHub remote off the main thread, once per path.
    /// No-op when the remote is already known or in flight. Safe to call from
    /// `.task`.
    func detectRepoURLIfNeeded(for project: Project) {
        guard project.gitHubRepo == nil else { return }
        let path = project.path
        guard detectedRepoURLs[path] == nil, !repoDetectionInFlight.contains(path) else { return }
        repoDetectionInFlight.insert(path)
        Task.detached(priority: .utility) {
            let url = detectGitHubOwnerRepo(at: path).flatMap { gitHubWebURL(forOwnerRepo: $0) }
            await MainActor.run {
                if let url { self.detectedRepoURLs[path] = url }
                self.repoDetectionInFlight.remove(path)
            }
        }
    }

    nonisolated private static func which(_ command: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fallback: run /usr/bin/env which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }
}

// MARK: - ExternalEditorMenu

struct ExternalEditorMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    /// Pull request for the selected project's current branch, when one is known
    /// (mirrors the briefing card). Drives the dedicated "Open Pull Request" item.
    private func pullRequestURL(for project: Project) -> URL? {
        _ = appState.ciStatusRevision
        guard let status = appState.ciStatusByProject[project.id] else { return nil }
        if let prUrl = status.prUrl, let url = URL(string: prUrl) {
            return url
        }
        if let prNumber = status.prNumber {
            return URL(string: "https://github.com/\(status.owner)/\(status.repo)/pull/\(prNumber)")
        }
        return nil
    }

    var body: some View {
        Menu {
            let editors = ExternalEditorService.shared.detectedEditors
            if editors.isEmpty {
                Text("No editors detected")
            } else {
                ForEach(editors) { editor in
                    Button {
                        if let path = windowState.selectedProject?.path {
                            ExternalEditorService.shared.open(editor, path: path)
                        }
                    } label: {
                        Label(editor.displayName, systemImage: editor.systemSymbol)
                    }
                }
            }
            Divider()
            if let project = windowState.selectedProject {
                if let prURL = pullRequestURL(for: project) {
                    Button {
                        NSWorkspace.shared.open(prURL)
                    } label: {
                        Label("Open Pull Request", systemImage: "arrow.triangle.pull")
                    }
                }
                if let repoURL = ExternalEditorService.shared.gitHubURL(for: project) {
                    Button {
                        NSWorkspace.shared.open(repoURL)
                    } label: {
                        Label("Open Repository", systemImage: "globe")
                    }
                }
            }
            Button {
                if let path = windowState.selectedProject?.path {
                    ExternalEditorService.shared.revealInFinder(path)
                }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .help("Open in External Editor")
        .disabled(windowState.selectedProject == nil)
        .task(id: windowState.selectedProject?.id) {
            ExternalEditorService.shared.detectIfNeeded()
            if let project = windowState.selectedProject {
                ExternalEditorService.shared.detectRepoURLIfNeeded(for: project)
            }
        }
    }
}
