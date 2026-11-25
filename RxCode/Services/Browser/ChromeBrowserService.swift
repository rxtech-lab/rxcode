import AppKit
import Combine
import Foundation
import ImageIO
import RxCodeCore

// MARK: - CDP Errors & Messages

nonisolated enum ChromeBrowserError: LocalizedError, Sendable {
    case runtimeNotInstalled
    case launchFailed(String)
    case connectionClosed
    case protocolError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            String(localized: "Chrome browser runtime is not installed. Download Chrome in Settings to use the Chrome engine.")
        case .launchFailed(let message):
            String(localized: "Couldn’t start Chrome: \(message)")
        case .connectionClosed:
            String(localized: "The connection to Chrome was closed.")
        case .protocolError(let message):
            message
        case .invalidResponse(let message):
            String(localized: "Unexpected response from Chrome: \(message)")
        }
    }
}

nonisolated struct CDPEvent: Sendable {
    let method: String
    let params: JSONValue
    let sessionId: String?
}

private nonisolated struct CDPRequest: Encodable, Sendable {
    let id: Int
    let method: String
    let params: [String: JSONValue]?
    let sessionId: String?
}

private nonisolated struct CDPMessage: Decodable, Sendable {
    struct ErrorBody: Decodable, Sendable {
        let code: Int?
        let message: String
    }

    let id: Int?
    let result: JSONValue?
    let error: ErrorBody?
    let method: String?
    let params: JSONValue?
    let sessionId: String?
}

// MARK: - Headless Chrome Process & Multiplexed CDP Client

/// Owns a single shared headless Chrome process and browser-level CDP WebSocket
/// connection. Individual workspace tabs attach via CDP flattened sessions.
actor ChromeBrowserService {
    static let shared = ChromeBrowserService()

    private var process: Process?
    private var launchedExecutablePath: String?
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var nextCommandID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var sessionHandlers: [String: @Sendable (CDPEvent) -> Void] = [:]
    private var browserHandlers: [UUID: @Sendable (CDPEvent) -> Void] = [:]
    private var terminationObserver: (any NSObjectProtocol)?

    init() {
        Task { @MainActor in
            let observer = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    await ChromeBrowserService.shared.stop()
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 2)
            }
            await self.storeTerminationObserver(observer)
        }
    }

    private func storeTerminationObserver(_ observer: any NSObjectProtocol) {
        terminationObserver = observer
    }

    var isRunning: Bool {
        process?.isRunning == true && webSocket != nil
    }

    /// Ensures Chrome is running and connected to its browser-level CDP endpoint.
    func ensureConnected() async throws {
        let runtime = await MainActor.run { BrowserEngineManager.shared.effectiveChromeRuntime }
        guard let runtime else { throw ChromeBrowserError.runtimeNotInstalled }

        if process?.isRunning == true, webSocket != nil, launchedExecutablePath == runtime.executablePath {
            return
        }

        if let existing = startTask {
            try await existing.value
            return
        }

        let task = Task {
            try await self.launchAndConnect(runtime: runtime)
        }
        startTask = task
        do {
            try await task.value
            startTask = nil
        } catch {
            startTask = nil
            throw error
        }
    }

    private func launchAndConnect(runtime: ChromeBrowserRuntimeInstaller.Runtime) async throws {
        stop()

        let profileDir = ChromeBrowserRuntimeInstaller.profileDirectory()
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        var arguments = [
            "--headless=new",
            "--remote-debugging-port=0",
            "--user-data-dir=\(profileDir.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-sync",
            "--window-size=1280,900",
        ]

        // Managed Chrome for Testing still supports loading unpacked extensions.
        if runtime.source == .managed {
            let extensionPaths: [String] = await MainActor.run {
                let manager = BrowserExtensionManager.shared
                manager.start()
                return manager.installed
                    .filter(\.isEnabled)
                    .map { manager.folder(for: $0.id).path }
                    .filter { FileManager.default.fileExists(atPath: $0) }
            }
            if !extensionPaths.isEmpty {
                let joined = extensionPaths.joined(separator: ",")
                arguments.append("--disable-extensions-except=\(joined)")
                arguments.append("--load-extension=\(joined)")
            }
        }

        arguments.append("about:blank")

        let child = Process()
        child.executableURL = URL(filePath: runtime.executablePath)
        child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        child.standardError = stderrPipe

        let wsURL = try await Self.launchAndReadDevToolsURL(process: child, stderrPipe: stderrPipe)

        let config = URLSessionConfiguration.ephemeral
        let urlSession = URLSession(configuration: config)
        let task = urlSession.webSocketTask(with: wsURL)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()

        self.process = child
        self.launchedExecutablePath = runtime.executablePath
        self.session = urlSession
        self.webSocket = task
        self.receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }

        // Enable target discovery so popup windows (`target="_blank"`) can be intercepted.
        _ = try? await send(method: "Target.setDiscoverTargets", params: ["discover": .bool(true)])
    }

    private static func launchAndReadDevToolsURL(process: Process, stderrPipe: Pipe) async throws -> URL {
        let handle = stderrPipe.fileHandleForReading
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let lock = NSLock()
                    var settled = false
                    var buffer = ""

                    func settle(_ result: Result<URL, Error>) {
                        lock.lock()
                        let shouldResume = !settled
                        settled = true
                        lock.unlock()
                        if shouldResume {
                            continuation.resume(with: result)
                        }
                    }

                    handle.readabilityHandler = { fileHandle in
                        let data = fileHandle.availableData
                        if data.isEmpty {
                            fileHandle.readabilityHandler = nil
                            let detail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                            settle(.failure(ChromeBrowserError.launchFailed(
                                detail.isEmpty ? "Chrome exited before opening DevTools." : String(detail.suffix(400))
                            )))
                            return
                        }
                        lock.lock()
                        let alreadySettled = settled
                        lock.unlock()
                        if alreadySettled { return }

                        if let chunk = String(data: data, encoding: .utf8) {
                            buffer += chunk
                            if let url = Self.extractDevToolsURL(from: buffer) {
                                settle(.success(url))
                            }
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        handle.readabilityHandler = nil
                        settle(.failure(ChromeBrowserError.launchFailed(error.localizedDescription)))
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw ChromeBrowserError.launchFailed("Timed out waiting for Chrome DevTools.")
            }

            guard let result = try await group.next() else {
                throw ChromeBrowserError.launchFailed("Chrome failed to start.")
            }
            group.cancelAll()
            return result
        }
    }

    nonisolated static func extractDevToolsURL(from output: String) -> URL? {
        guard let range = output.range(of: #"ws://127\.0\.0\.1:\d+/devtools/browser/\S+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(output[range]))
    }

    /// Terminates the headless Chrome process and clears all pending CDP requests.
    func stop() {
        receiveTask?.cancel()
        receiveTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        session?.invalidateAndCancel()
        session = nil

        if let child = process {
            if let stderr = child.standardError as? Pipe {
                stderr.fileHandleForReading.readabilityHandler = nil
            }
            if child.isRunning {
                child.terminate()
                let deadline = Date().addingTimeInterval(1.5)
                while child.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
        launchedExecutablePath = nil

        failAllPending(with: ChromeBrowserError.connectionClosed)
        sessionHandlers.removeAll()
    }

    func registerSessionHandler(sessionId: String, handler: @escaping @Sendable (CDPEvent) -> Void) {
        sessionHandlers[sessionId] = handler
    }

    func unregisterSessionHandler(sessionId: String) {
        sessionHandlers.removeValue(forKey: sessionId)
    }

    func registerBrowserHandler(id: UUID, handler: @escaping @Sendable (CDPEvent) -> Void) {
        browserHandlers[id] = handler
    }

    func unregisterBrowserHandler(id: UUID) {
        browserHandlers.removeValue(forKey: id)
    }

    @discardableResult
    func send(
        method: String,
        params: [String: JSONValue]? = nil,
        sessionId: String? = nil
    ) async throws -> JSONValue {
        try await ensureConnected()
        guard let webSocket else { throw ChromeBrowserError.connectionClosed }

        let id = nextCommandID
        nextCommandID += 1

        let payload = try JSONEncoder().encode(CDPRequest(id: id, method: method, params: params, sessionId: sessionId))
        guard let text = String(data: payload, encoding: .utf8) else {
            throw ChromeBrowserError.invalidResponse("Could not encode CDP command.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            webSocket.send(.string(text)) { [weak self] error in
                if let error {
                    Task { await self?.failPending(id: id, error: error) }
                }
            }
        }
    }

    func createTabSession(url: String = "about:blank") async throws -> (targetId: String, sessionId: String) {
        let created = try await send(method: "Target.createTarget", params: [
            "url": .string(url),
        ])
        guard let targetId = created["targetId"]?.stringValue else {
            throw ChromeBrowserError.invalidResponse("Missing targetId from Target.createTarget.")
        }
        return try await attachToTarget(targetId: targetId)
    }

    func attachToTarget(targetId: String) async throws -> (targetId: String, sessionId: String) {
        let attached = try await send(method: "Target.attachToTarget", params: [
            "targetId": .string(targetId),
            "flatten": .bool(true),
        ])
        guard let sessionId = attached["sessionId"]?.stringValue else {
            throw ChromeBrowserError.invalidResponse("Missing sessionId from Target.attachToTarget.")
        }
        return (targetId, sessionId)
    }

    func closeTarget(targetId: String) async {
        guard webSocket != nil else { return }
        _ = try? await send(method: "Target.closeTarget", params: ["targetId": .string(targetId)])
    }

    /// Sets decrypted Chrome cookies into the running headless Chrome profile via CDP.
    func importCookies(_ cookies: [ChromeCookie]) async throws -> Int {
        guard !cookies.isEmpty else { return 0 }
        try await ensureConnected()
        let encoded: [JSONValue] = cookies.map { cookie in
            var obj: [String: JSONValue] = [
                "name": .string(cookie.name),
                "value": .string(cookie.value),
                "domain": .string(cookie.domain),
                "path": .string(cookie.path.isEmpty ? "/" : cookie.path),
                "secure": .bool(cookie.isSecure),
                "httpOnly": .bool(cookie.isHTTPOnly),
            ]
            if let expires = cookie.expires {
                obj["expires"] = .number(expires.timeIntervalSince1970)
            }
            switch cookie.sameSite {
            case 0: obj["sameSite"] = .string("None")
            case 1: obj["sameSite"] = .string("Lax")
            case 2: obj["sameSite"] = .string("Strict")
            default: break
            }
            return .object(obj)
        }
        _ = try await send(method: "Storage.setCookies", params: ["cookies": .array(encoded)])
        return encoded.count
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: continue
                }
                handleRawMessage(data)
            } catch {
                if task === self.webSocket {
                    handleDisconnect(error)
                }
                return
            }
        }
    }

    private func handleRawMessage(_ data: Data) {
        guard let message = try? JSONDecoder().decode(CDPMessage.self, from: data) else { return }
        if let id = message.id {
            if let error = message.error {
                failPending(id: id, error: ChromeBrowserError.protocolError(error.message))
            } else {
                if let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(returning: message.result ?? .object([:]))
                }
            }
            return
        }
        if let method = message.method {
            let event = CDPEvent(method: method, params: message.params ?? .object([:]), sessionId: message.sessionId)
            if let sid = message.sessionId {
                sessionHandlers[sid]?(event)
            } else {
                for handler in browserHandlers.values {
                    handler(event)
                }
            }
        }
    }

    private func failPending(id: Int, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func failAllPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func handleDisconnect(_ error: Error) {
        webSocket = nil
        failAllPending(with: error)
        let event = CDPEvent(method: "RxCode.disconnected", params: .object([:]), sessionId: nil)
        for handler in sessionHandlers.values {
            handler(event)
        }
    }
}
