import AppKit
import RxCodeCore
import ScreenCaptureKit

nonisolated struct DesignTarget: Identifiable, Hashable, Sendable {
    enum Platform: String, CaseIterable, Sendable { case iOS, Android, macOS }
    let platform: Platform
    let identifier: String
    let name: String
    var id: String { "\(platform.rawValue):\(identifier)" }
}

/// Commands take argument arrays. Binary captures and diagnostics use separate files.
nonisolated enum DesignCommand {
    static func run(_ executable: String, _ arguments: [String], timeout seconds: Int = 25) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output"), errors = root.appendingPathComponent("errors")
        try Data().write(to: output)
        try Data().write(to: errors)
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout
        process.standardError = stderr
        let (exits, completion) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { child in
            completion.yield(child.terminationStatus)
            completion.finish()
        }
        defer { process.terminationHandler = nil; completion.finish() }
        try Task.checkCancellation()
        try process.run()
        let timeout = Task.detached {
            try await Task.sleep(for: .seconds(seconds))
            if process.isRunning { process.terminate() }
            completion.finish()
        }
        defer { timeout.cancel() }
        let exitCode = await withTaskCancellationHandler {
            var iterator = exits.makeAsyncIterator()
            return await iterator.next()
        } onCancel: { if process.isRunning { process.terminate() } }
        try Task.checkCancellation()
        guard let exitCode else { throw IDEToolError.handlerFailed("The device command timed out after \(seconds) seconds.") }
        guard exitCode == 0 else {
            let log = (try? String(contentsOf: errors, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw IDEToolError.handlerFailed(log.flatMap { $0.isEmpty ? nil : String($0.prefix(1800)) } ?? "The device command failed or timed out.")
        }
        return try Data(contentsOf: output)
    }

    static func binary(_ name: String, additional: [String] = []) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (additional + ["/opt/homebrew/bin", "/usr/local/bin"] + path.components(separatedBy: ":"))
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

actor DesignTargetService {
    let desktop = PetDesktopDriver()

    func targets(_ platform: DesignTarget.Platform) async throws -> [DesignTarget] {
        switch platform {
        case .macOS:
            let windows = await desktop.windows().filter { $0.onScreen && $0.pid != getpid() && !$0.title.isEmpty }
            if windows.isEmpty && !ComputerUseWindowCapture.hasAccess {
                throw IDEToolError.handlerFailed("Allow RxCode in System Settings → Privacy & Security → Screen & System Audio Recording to preview Mac windows.")
            }
            return windows.map {
                DesignTarget(platform: platform, identifier: "\($0.pid)/\($0.id)", name: "\($0.app) · \($0.title)")
            }
        case .iOS:
            let data = try await DesignCommand.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "--json"])
            let devices = try JSONDecoder().decode(JSONValue.self, from: data)["devices"]?.objectValue ?? [:]
            return devices.sorted { $0.key < $1.key }.filter { $0.key.contains(".iOS-") }.flatMap { item in
                (item.value.arrayValue ?? []).compactMap { device -> DesignTarget? in
                    guard let id = device["udid"]?.stringValue, let name = device["name"]?.stringValue else { return nil }
                    return .init(platform: platform, identifier: id, name: name)
                }
            }
        case .Android:
            let data = try await DesignCommand.run(try adb(), ["devices", "-l"])
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count > 1, fields[0].hasPrefix("emulator-"), fields[1] == "device" else { return nil }
                let name = fields.first { $0.hasPrefix("model:") }.map { $0.dropFirst(6).replacingOccurrences(of: "_", with: " ") }
                return .init(platform: platform, identifier: String(fields[0]), name: "\(name ?? "Android") · \(fields[0])")
            }
        }
    }

    func capture(_ target: DesignTarget) async throws -> Data {
        switch target.platform {
        case .iOS:
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await DesignCommand.run("/usr/bin/xcrun", ["simctl", "io", target.identifier, "screenshot", "--type=png", file.path])
            return try Data(contentsOf: file)
        case .Android:
            return try await android(target, ["exec-out", "screencap", "-p"])
        case .macOS:
            let targetWindow = try await window(target)
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == targetWindow.id && $0.owningApplication?.processID == targetWindow.pid }) else {
                throw IDEToolError.handlerFailed("This window is no longer available.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width * CGFloat(filter.pointPixelScale)))
            config.height = max(1, Int(window.frame.height * CGFloat(filter.pointPixelScale)))
            config.ignoreShadowsSingleWindow = true
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw IDEToolError.handlerFailed("The window did not return an image.")
            }
            return data
        }
    }

    private func window(_ target: DesignTarget) async throws -> PetDesktopWindow {
        guard let match = await desktop.windows().first(where: { "\($0.pid)/\($0.id)" == target.identifier && $0.pid != getpid() }) else {
            throw IDEToolError.handlerFailed("The selected Mac window has closed.")
        }
        return match
    }

    private func adb() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let sdks = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], NSHomeDirectory() + "/Library/Android/sdk"].compactMap { $0 }
        guard let path = DesignCommand.binary("adb", additional: sdks.map { $0 + "/platform-tools" }) else {
            throw IDEToolError.handlerFailed("Install Android SDK Platform-Tools and start an emulator in Android Studio.")
        }
        return path
    }

    private func android(_ target: DesignTarget, _ args: [String]) async throws -> Data {
        try await DesignCommand.run(try adb(), ["-s", target.identifier] + args)
    }

    private func ios(_ target: DesignTarget, _ arguments: [String]) async throws -> Data {
        guard let idb = DesignCommand.binary("idb", additional: [NSHomeDirectory() + "/.local/bin"]) else {
            throw IDEToolError.handlerFailed("Install Maestro or the idb client and idb-companion for iOS accessibility, taps, and typing.")
        }
        return try await DesignCommand.run(idb, arguments + ["--udid", target.identifier])
    }

    private func maestro(_ target: DesignTarget) -> MaestroDesignDriver? {
        DesignCommand.binary("maestro", additional: [NSHomeDirectory() + "/.maestro/bin"])
            .map { MaestroDesignDriver(executable: $0, device: target.identifier) }
    }

    private func iosSize(_ target: DesignTarget, pixels: CGSize) async throws -> CGSize {
        let data = try await ios(target, ["describe", "--json"])
        let info = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let density = info["screen_dimensions"]?["density"]?.numberValue, density > 0 else {
            throw IDEToolError.handlerFailed("idb did not report this simulator’s display scale.")
        }
        return CGSize(width: pixels.width / density, height: pixels.height / density)
    }

    func inspect(_ target: DesignTarget, at fraction: CGPoint, pixels: CGSize) async throws -> String {
        switch target.platform {
        case .Android:
            let xml = try await android(target, ["exec-out", "uiautomator", "dump", "/dev/tty"])
            return AndroidDesignElement.at(CGPoint(x: fraction.x * pixels.width, y: fraction.y * pixels.height), in: xml)
                ?? "No accessibility element at this point."
        case .iOS:
            if let driver = maestro(target) { return try MaestroDesignDriver.hit(await driver.hierarchy(), fraction: fraction).label }
            let size = try await iosSize(target, pixels: pixels)
            return String(decoding: try await ios(target, ["ui", "describe-point", String(Int(fraction.x * size.width)), String(Int(fraction.y * size.height)), "--json"]), as: UTF8.self)
        case .macOS:
            return try await desktop.designElement(in: window(target), fraction: fraction)
        }
    }

    func tap(_ target: DesignTarget, at fraction: CGPoint, pixels: CGSize) async throws {
        switch target.platform {
        case .Android:
            _ = try await android(target, ["shell", "input", "tap", String(Int(fraction.x * pixels.width)), String(Int(fraction.y * pixels.height))])
        case .iOS:
            if let driver = maestro(target) { try await driver.tap(fraction); return }
            let size = try await iosSize(target, pixels: pixels)
            _ = try await ios(target, ["ui", "tap", String(Int(fraction.x * size.width)), String(Int(fraction.y * size.height))])
        case .macOS:
            let window = try await desktop.focus(window(target), excluding: [])
            let point = CGPoint(x: window.frame.minX + fraction.x * window.frame.width, y: window.frame.minY + fraction.y * window.frame.height)
            try await desktop.click(window, point: point, excluding: [])
        }
    }

    func type(_ text: String, in target: DesignTarget) async throws {
        switch target.platform {
        case .Android:
            let quoted = "'" + text.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: " ", with: "%s") + "'"
            _ = try await android(target, ["shell", "input", "text", quoted])
        case .iOS:
            if let driver = maestro(target) { try await driver.type(text) }
            else { _ = try await ios(target, ["ui", "text", text]) }
        case .macOS:
            let window = try await desktop.focus(window(target), excluding: [])
            try await desktop.typeText(text, into: window, excluding: [])
        }
    }
}
