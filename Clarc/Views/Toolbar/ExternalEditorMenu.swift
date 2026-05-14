import SwiftUI
import AppKit
import ClarcCore

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
final class ExternalEditorService {
    static let shared = ExternalEditorService()

    private init() {}

    func detectedEditors() -> [ExternalEditor] {
        ExternalEditor.all.filter { isInstalled($0) }
    }

    func isInstalled(_ editor: ExternalEditor) -> Bool {
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
        if let cli = editor.cliCommand, let cliPath = which(cli) {
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

    private func which(_ command: String) -> String? {
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
    @Environment(WindowState.self) private var windowState

    var body: some View {
        Menu {
            let editors = ExternalEditorService.shared.detectedEditors()
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
    }
}
