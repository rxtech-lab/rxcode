import Foundation
import Darwin
import CryptoKit
import MLX
import class MLXLMCommon.ModelContainer
import os
import RxAgentHarness
import RxAgentCore

/// What the local inference server is doing, for the UI.
nonisolated enum LlamaServerStatus: Equatable, Sendable {
    case stopped
    case loading(modelID: String)
    case running(modelID: String, port: Int, contextSize: Int)
    case failed(String)

    var modelID: String? {
        switch self {
        case .loading(let id), .running(let id, _, _): id
        case .stopped, .failed: nil
        }
    }
}

/// Owns llama.cpp's GGUF server or a native MLX model and releases it when idle.
///
/// GGUF uses a server because: `llama-server` speaks the
/// OpenAI chat API with native tool-call parsing for every chat template
/// (`--jinja`), so the harness drives it exactly like any other
/// OpenAI-compatible endpoint, and a crash in inference cannot take RxCode
/// down with it. Memory is released by ending the process, which is also what
/// makes auto-release reliable — nothing lingers in RxCode's address space.
actor LlamaServerManager {
    static let shared = LlamaServerManager()

    enum ServerError: LocalizedError {
        case runtimeMissing
        case modelMissing(String)
        case exited(String)
        case timedOut
        case notLanguageModel(String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing: "The llama.cpp runtime is not installed. Install it from Settings → Agent → RxCode Agent."
            case .modelMissing(let path): "The model file is missing: \(path). Download the model again."
            case .notLanguageModel(let name): "\(name) has no model architecture metadata, so llama.cpp cannot load it. It is likely not a chat model (for example an image, audio or diffusion component). Choose a different GGUF file."
            case .exited(let log): "The local model server stopped while loading.\n\(log)"
            case .timedOut: "The local model server did not become ready in time."
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rxlab.RxCode", category: "LlamaServer")
    private var nativePromptCache = NativeMLXPromptCache()
    private var nativeContainer: ModelContainer?
    private var nativeTask: Task<Void, Error>?
    private var nativeOperation: UUID?
    private var process: Process?
    private var lifetimeWatchdog: Process?
    private var status: LlamaServerStatus = .stopped
    private var loadedModelID: String?
    private var resourceLogURL: URL?
    private var port = 0
    private var contextSize = 0
    private var activeRequests = 0
    private var lastActivity = Date()
    private var idleTimeout: TimeInterval = 15 * 60
    private var idleMonitor: Task<Void, Never>?
    private var loading: Task<URL, Error>?
    private var statusHandler: (@Sendable (LlamaServerStatus) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (LlamaServerStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    /// `0` disables automatic release.
    func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = seconds
    }

    var currentStatus: LlamaServerStatus { status }

    /// MLX allocator memory or resident RAM used by the GGUF server.
    func loadedModelMemoryBytes() -> UInt64? {
        guard let loadedModelID else { return nil }
        return resourceUsage(modelID: loadedModelID).memory
    }

    /// Samples native MLX allocations or the managed GGUF process. Buffers share unified memory.
    func resourceUsage(modelID: String) -> (memory: UInt64?, gpu: UInt64?, context: Int?) {
        if loadedModelID == modelID, nativeContainer != nil {
            return (UInt64(Memory.activeMemory + Memory.cacheMemory), UInt64(Memory.activeMemory), contextSize)
        }
        guard loadedModelID == modelID, let process, process.isRunning else {
            return (nil, nil, nil)
        }
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let result = proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(size))
        var gpu: UInt64?
        if let resourceLogURL, let file = try? FileHandle(forReadingFrom: resourceLogURL) {
            defer { try? file.close() }
            // Startup allocation lines precede request logs. Bound reads even for long sessions.
            if let data = try? file.read(upToCount: 262_144), let log = String(data: data, encoding: .utf8) {
                gpu = Self.gpuBufferBytes(in: log)
            }
        }
        return (result == size ? info.pti_resident_size : nil, gpu, contextSize)
    }

    nonisolated static func gpuBufferBytes(in log: String) -> UInt64? {
        let pattern = #"Metal[^\n]*?buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*MiB"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = log as NSString
        let matches = regex.matches(in: log, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return nil }
        let mib = matches.reduce(0.0) { $0 + (Double(source.substring(with: $1.range(at: 1))) ?? 0) }
        guard mib.isFinite, mib >= 0, mib < Double(UInt64.max) / 1_048_576 else { return nil }
        return UInt64(mib * 1_048_576)
    }

    /// Starts (or reuses) a server for `model` and returns its base URL.
    func ensureServer(
        for model: LocalModelInfo,
        modelsRoot: URL,
        runtime: URL,
        contextSize requestedContext: Int
    ) async throws -> (baseURL: URL, contextSize: Int) {
        guard model.format == .gguf else { throw HarnessModelError.unavailable("MLX uses native inference.") }
        guard nativeOperation == nil else { throw HarnessModelError.unavailable("The local model is busy. Try again when the current request finishes.") }
        lastActivity = Date()
        if loadedModelID == model.id, let process, process.isRunning, case .running = status {
            return (Self.baseURL(port: port), contextSize)
        }
        if let loading, status.modelID == model.id {
            return (try await loading.value, contextSize)
        }
        stop()

        let modelURL = model.primaryFile(in: modelsRoot)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ServerError.modelMissing(modelURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else { throw ServerError.runtimeMissing }
        // llama-server exits with "unknown model architecture: ''" otherwise.
        // Unreadable headers fall through so llama.cpp reports the real problem.
        // `try?` would flatten "no architecture" into "unreadable"; keep them apart.
        let architecture: String??
        do { architecture = .some(try GGUFHeader.architecture(of: modelURL)) } catch { architecture = .none }
        if case .some(.none) = architecture {
            throw ServerError.notLanguageModel(modelURL.lastPathComponent)
        }

        let context = min(requestedContext, model.contextLength ?? requestedContext)
        let port = Self.freePort()
        let logURL = modelsRoot.appending(path: model.format == .mlx ? "mlx-server.log" : "llama-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = runtime
        switch model.format {
        case .gguf:
            process.arguments = [
                "--model", modelURL.path,
                "--alias", model.id,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--ctx-size", String(context),
                "--n-gpu-layers", "999",
                "--jinja",
                "--no-webui",
                // One slot: the harness runs one turn per session, and a single
                // slot gives that turn the whole context window.
                "--parallel", "1",
            ]
        case .mlx:
            throw HarnessModelError.unavailable("MLX uses native inference.")
        }
        // The runtime's dylibs sit next to the binary.
        process.currentDirectoryURL = runtime.deletingLastPathComponent()
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice

        logger.info("starting \(model.format.runtimeName, privacy: .public) server model=\(model.id, privacy: .public) port=\(port) ctx=\(context)")
        try process.run()
        do {
            lifetimeWatchdog = try Self.startLifetimeWatchdog(for: process)
        } catch {
            kill(process.processIdentifier, SIGKILL)
            throw error
        }
        self.resourceLogURL = model.format == .gguf ? logURL : nil
        self.process = process
        self.loadedModelID = model.id
        self.port = port
        self.contextSize = context
        publish(.loading(modelID: model.id))
        startIdleMonitor()

        let task = Task<URL, Error> {
            let url = Self.baseURL(port: port)
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                try Task.checkCancellation()
                if !process.isRunning {
                    throw ServerError.exited(Self.tail(of: logURL))
                }
                if await Self.isHealthy(port: port) { return url }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ServerError.timedOut
        }
        loading = task
        do {
            let url = try await task.value
            guard self.process === process else { throw CancellationError() }
            loading = nil
            publish(.running(modelID: model.id, port: port, contextSize: context))
            lastActivity = Date()
            return (url, context)
        } catch {
            // A cancelled load can finish after another model has started.
            // It must not stop that replacement server or overwrite its status.
            if self.process === process {
                loading = nil
                stop()
                publish(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    /// One native generation at a time, including model loading. Cancellation
    /// keeps the slot occupied until the previous operation has actually exited.
    func generateNative(
        model: LocalModelInfo, modelsRoot: URL, context: Int, request: HarnessModelRequest,
        continuation: AsyncThrowingStream<HarnessModelChunk, Error>.Continuation
    ) async throws {
        guard nativeOperation == nil, activeRequests == 0 else {
            throw HarnessModelError.unavailable("The local model is busy. Try again when the current request finishes.")
        }
        let context = min(context, model.contextLength ?? context)
        if loadedModelID != model.id || contextSize != context { stop() }
        let operation = UUID()
        nativeOperation = operation
        beginRequest()
        let task = Task {
            do {
                try Task.checkCancellation()
                if nativeContainer == nil {
                    loadedModelID = model.id
                    contextSize = context
                    publish(.loading(modelID: model.id))
                    let container = try await NativeMLXInference.load(directory: model.directory(in: modelsRoot))
                    try Task.checkCancellation()
                    nativeContainer = container
                    publish(.running(modelID: model.id, port: 0, contextSize: context))
                    startIdleMonitor()
                }
                guard let container = nativeContainer else { throw CancellationError() }
                try await NativeMLXInference.generate(container: container, request: request,
                    contextSize: context,
                    // The SDK sends checkpoint summaries in generation mode.
                    // Keep those one-off prompts out of the streaming chat cache.
                    promptCache: request.mode == .streaming ? nativePromptCache : NativeMLXPromptCache(),
                    continuation: continuation)
            } catch {
                if request.mode == .streaming { nativePromptCache = NativeMLXPromptCache() }
                if !Task.isCancelled, nativeContainer == nil { publish(.failed(error.localizedDescription)) }
                throw error
            }
        }
        nativeTask = task
        defer {
            nativeTask = nil
            nativeOperation = nil
            endRequest()
            Memory.clearCache()
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func beginRequest() {
        activeRequests += 1
        lastActivity = Date()
    }

    func endRequest() {
        activeRequests = max(0, activeRequests - 1)
        lastActivity = Date()
    }

    /// Ends the server and frees the model's memory.
    func stop() {
        nativePromptCache = NativeMLXPromptCache()
        if nativeContainer != nil || nativeTask != nil {
            nativeTask?.cancel()
            nativeContainer = nil
            Memory.clearCache()
        }
        loading?.cancel()
        loading = nil
        idleMonitor?.cancel()
        idleMonitor = nil
        if let process, process.isRunning {
            logger.info("stopping llama-server model=\(self.loadedModelID ?? "-", privacy: .public)")
            // Inference servers have no data to flush. SIGTERM alone can leave
            // inference threads resident, and quit cannot await a retry.
            kill(process.processIdentifier, SIGKILL)
        }
        if let lifetimeWatchdog, lifetimeWatchdog.isRunning {
            lifetimeWatchdog.terminate()
        }
        lifetimeWatchdog = nil
        process = nil
        loadedModelID = nil
        activeRequests = 0
        if case .failed = status {} else { publish(.stopped) }
    }

    /// Stops the server if it is serving `modelID` — called before that model's
    /// files are deleted.
    func unload(modelID: String) {
        if loadedModelID == modelID { stop() }
    }

    // MARK: - Private

    /// Runs independently so debugger stops and crashes also release model RAM.
    /// Compare the process start time before signaling to avoid targeting a reused PID.
    nonisolated static func startLifetimeWatchdog(for server: Process) throws -> Process {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", """
        server="$1"
        owner="$2"
        started=$(/bin/ps -p "$server" -o lstart=)
        [ -n "$started" ] || exit 0
        while /bin/kill -0 "$server" 2>/dev/null; do
            current=$(/bin/ps -p "$server" -o lstart=)
            [ "$current" = "$started" ] || exit 0
            parent=$(/bin/ps -p "$server" -o ppid= | /usr/bin/tr -d ' ')
            if [ "$parent" != "$owner" ]; then
                /bin/kill -KILL "$server" 2>/dev/null
                exit 0
            fi
            /bin/sleep 2
        done
        """, "rxcode-model-watchdog", String(server.processIdentifier), String(ProcessInfo.processInfo.processIdentifier)]
        watchdog.standardInput = FileHandle.nullDevice
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try watchdog.run()
        return watchdog
    }

    private func publish(_ status: LlamaServerStatus) {
        self.status = status
        statusHandler?(status)
    }

    private func startIdleMonitor() {
        idleMonitor?.cancel()
        idleMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                await self?.releaseIfIdle()
            }
        }
    }

    private func releaseIfIdle() {
        guard idleTimeout > 0, (process != nil || nativeContainer != nil),
              activeRequests == 0, nativeOperation == nil, loading == nil else { return }
        if Date().timeIntervalSince(lastActivity) >= idleTimeout {
            logger.info("auto-releasing idle model \(self.loadedModelID ?? "-", privacy: .public)")
            stop()
            idleMonitor?.cancel()
            idleMonitor = nil
        }
    }

    static func baseURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    private static func isHealthy(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Asks the kernel for an unused loopback port.
    private static func freePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return Int.random(in: 49_152...60_000) }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, length) == 0 && getsockname(socketFD, $0, &length) == 0
            }
        }
        guard bound else { return Int.random(in: 49_152...60_000) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func tail(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(12).joined(separator: "\n")
    }
}

/// A harness model served by the managed server. Counts in-flight requests so
/// the idle monitor never releases a model mid-answer.
nonisolated struct LocalLlamaHarnessModel: HarnessModel {
    let base: OpenAICompatibleHarnessModel
    let manager: LlamaServerManager

    var contextWindow: Int? { base.contextWindow }

    func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        let base = base
        let manager = manager
        return AsyncThrowingStream { continuation in
            let task = Task {
                await manager.beginRequest()
                do {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appending(path: "RxCode/local-tool-context")
                    let request = try LocalModelContext.compact(request, directory: directory)
                    if let window = base.contextWindow {
                        try LocalModelContext.checkCompaction(request, promptTokens: TokenEstimator.estimate(
                            system: request.system, messages: request.messages, tools: request.tools), contextSize: window)
                    }
                    for try await chunk in base.send(request) {
                        if case .usage(let usage) = chunk {
                            Logger(subsystem: "com.rxlab.RxCode", category: "LocalPromptCache")
                                .info("prompt_tokens=\(usage.inputTokens) cached_tokens=\(usage.cacheReadTokens)")
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await manager.endRequest()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Keeps executable schemas intact while moving verbose tool documentation out
/// of the prompt. Full documentation remains readable by the harness's file tool.
nonisolated enum LocalModelContext {
    /// `VideoGenerationProgress.toolName`; this file doesn't import RxCodeCore.
    static let videoToolName = "VideoGeneration"
    /// Every studio tool (`LocalStudioKind.toolNames`).
    static let studioToolNames: Set<String> = [videoToolName, "ImageGeneration", "AudioGeneration", "Decision"]

    private static let coreTools: Set<String> = [
        "read", "glob", "grep", "bash", "edit", "write", "patch", "todowrite", "todoread", "question",
    ]

    /// Check only the prompt that will actually reach inference. Leave enough
    /// room for output; skip proactive checks when no earlier turn can be folded.
    static func checkCompaction(_ request: HarnessModelRequest, promptTokens: Int, contextSize: Int) throws {
        guard request.mode == .streaming,
              request.messages.filter({ $0.role == .user }).count > 1,
              promptTokens > HarnessCompactionPolicy.default.threshold(contextWindow: contextSize) else { return }
        throw HarnessModelError.contextOverflow("The prepared local prompt needs compaction (\(promptTokens) tokens).")
    }

    static func compact(_ input: HarnessModelRequest, directory: URL) throws -> HarnessModelRequest {
        var request = input
        var catalogEntries: [String] = []
        let calls = input.messages.flatMap(\.toolCalls)
        let canReadDocumentation = input.tools.contains { $0.name == "read" }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.tools = try input.tools.sorted { $0.name < $1.name }.compactMap { tool -> HarnessToolSpec? in
            // Only studio models call these; chat models can't produce a clip,
            // an image, audio or a calibrated decision.
            if studioToolNames.contains(tool.name) { return nil }
            // Discovery must be usable without first reading its own manual.
            if coreTools.contains(tool.name) { return tool }
            let parameters = compactSchema(tool.parameters)
            let schemaBytes = try encoder.encode(parameters).count
            let shouldDefer = canReadDocumentation && !coreTools.contains(tool.name)
            guard shouldDefer || tool.description.count > 400 || parameters != tool.parameters || schemaBytes > 2_000 else { return tool }
            let filename = SHA256.hash(data: Data(tool.name.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = directory.appending(path: filename + ".json")
            let documentation: JSONValue = .object([
                "name": .string(tool.name), "description": .string(tool.description),
                "parameters": tool.parameters,
            ])
            let data = try encoder.encode(documentation)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
            let isActivated = calls.contains {
                $0.name == tool.name || ($0.name == "read" && $0.argumentsJSON.contains(filename))
            }
            if shouldDefer {
                // Keep the catalog (and its system-prompt path) stable as tools
                // activate. Only the callable schema list needs to change.
                catalogEntries.append("- \(tool.name): \(tool.description.prefix(160))\n  File: \(url.path)")
                if !isActivated { return nil }
            }
            return HarnessToolSpec(
                name: tool.name,
                description: String(tool.description.prefix(400)) + "\nRead full documentation before using this tool: \(url.path)",
                parameters: parameters
            )
        }
        if !catalogEntries.isEmpty {
            let catalog = "# Available service tools\nRead a tool's documentation file to make it callable on the next step.\n" + catalogEntries.joined(separator: "\n")
            // A content-addressed catalog prevents concurrent threads with
            // different tool sets from overwriting each other's discovery list.
            let digest = SHA256.hash(data: Data(catalog.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = directory.appending(path: "catalog-\(digest).md")
            if !FileManager.default.fileExists(atPath: url.path) {
                try catalog.write(to: url, atomically: true, encoding: .utf8)
            }
            request.system += "\n\n# Service tools\nAdditional tools for connected services and IDE operations are available on demand. When the task needs them, read the catalog at \(url.path), then read the relevant tool's documentation file. Its schema becomes callable on your next step. Skip discovery for greetings and tasks covered by the current tools."
        }
        return request
    }

    static func compactSchema(_ schema: JSONValue) -> JSONValue {
        guard case .object(var fields) = schema else { return schema }
        if case .string(let description) = fields["description"] {
            fields["description"] = .string(String(description.prefix(160)))
        }
        // Only traverse schema positions; property names and literal values
        // (including enum/default objects) must never be rewritten.
        for key in ["properties", "$defs", "definitions", "patternProperties"] {
            if case .object(let children) = fields[key] {
                fields[key] = .object(children.mapValues(compactSchema))
            }
        }
        for key in ["items", "additionalProperties", "not", "if", "then", "else"] {
            if let child = fields[key] { fields[key] = compactSchema(child) }
        }
        for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            if case .array(let children) = fields[key] {
                fields[key] = .array(children.map(compactSchema))
            }
        }
        return .object(fields)
    }
}

/// Reads `general.architecture` from a GGUF header without loading tensors.
nonisolated enum GGUFHeader {
    enum ReadError: Error { case notGGUF, truncated, unsupportedType(UInt32) }

    /// `nil` when the file is valid GGUF but declares no architecture.
    static func architecture(of url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else { throw ReadError.notGGUF }
        _ = try read(UInt32.self, file) // version
        _ = try read(UInt64.self, file) // tensor count
        let count = try read(UInt64.self, file)
        for _ in 0..<min(count, 4_096) {
            let key = try readString(file)
            let type = try read(UInt32.self, file)
            if key == "general.architecture", type == 8 {
                let value = try readString(file)
                return value.isEmpty ? nil : value
            }
            try skipValue(type: type, file)
        }
        return nil
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, _ file: FileHandle) throws -> T {
        let size = MemoryLayout<T>.size
        guard let data = try file.read(upToCount: size), data.count == size else { throw ReadError.truncated }
        return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }

    private static func readString(_ file: FileHandle) throws -> String {
        let length = try read(UInt64.self, file)
        guard length <= 1_048_576 else { throw ReadError.truncated }
        guard length > 0 else { return "" }
        guard let data = try file.read(upToCount: Int(length)), data.count == Int(length) else { throw ReadError.truncated }
        return String(decoding: data, as: UTF8.self)
    }

    private static func skipValue(type: UInt32, _ file: FileHandle) throws {
        switch type {
        case 8:
            let length = try read(UInt64.self, file)
            try file.seek(toOffset: try file.offset() + length)
        case 9:
            let elementType = try read(UInt32.self, file)
            let count = try read(UInt64.self, file)
            if let size = fixedSize(elementType) {
                try file.seek(toOffset: try file.offset() + count * size)
            } else {
                for _ in 0..<count { try skipValue(type: elementType, file) }
            }
        default:
            guard let size = fixedSize(type) else { throw ReadError.unsupportedType(type) }
            try file.seek(toOffset: try file.offset() + size)
        }
    }

    static func fixedSize(_ type: UInt32) -> UInt64? {
        switch type {
        case 0, 1, 7: 1
        case 2, 3: 2
        case 4, 5, 6: 4
        case 10, 11, 12: 8
        default: nil
        }
    }
}

extension GGUFHeader {
    /// The `general.*` string and number entries in the first bytes of a GGUF
    /// file, e.g. from a range request. Stops quietly where the bytes run out,
    /// since big arrays (the tokenizer) usually follow the `general` block.
    static func generalMetadata(in data: Data) -> [String: String] {
        var cursor = Cursor(data: data)
        guard cursor.bytes(4) == Data("GGUF".utf8),
              cursor.integer(UInt32.self) != nil, cursor.integer(UInt64.self) != nil,
              let count = cursor.integer(UInt64.self) else { return [:] }
        var metadata: [String: String] = [:]
        for _ in 0..<min(count, 4_096) {
            guard let key = cursor.string(), let type = cursor.integer(UInt32.self) else { break }
            let isGeneral = key.hasPrefix("general.")
            switch type {
            case 8:
                guard let value = cursor.string() else { return metadata }
                if isGeneral, !value.isEmpty { metadata[key] = String(value.prefix(200)) }
            case 4, 5:
                guard let value = cursor.integer(UInt32.self) else { return metadata }
                if isGeneral { metadata[key] = type == 4 ? String(value) : String(Int32(bitPattern: value)) }
            case 10, 11:
                guard let value = cursor.integer(UInt64.self) else { return metadata }
                if isGeneral { metadata[key] = type == 10 ? String(value) : String(Int64(bitPattern: value)) }
            case 9:
                guard let elementType = cursor.integer(UInt32.self), let length = cursor.integer(UInt64.self) else { return metadata }
                if let size = fixedSize(elementType) {
                    guard cursor.skip(length * size) else { return metadata }
                } else if elementType == 8 {
                    for _ in 0..<length { guard cursor.string() != nil else { return metadata } }
                } else {
                    return metadata
                }
            default:
                guard let size = fixedSize(type), cursor.skip(size) else { return metadata }
            }
        }
        return metadata
    }

    private struct Cursor {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return data[start..<start + count]
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            bytes(MemoryLayout<T>.size).map { T(littleEndian: $0.withUnsafeBytes { $0.loadUnaligned(as: T.self) }) }
        }

        mutating func string() -> String? {
            guard let length = integer(UInt64.self), length <= 1_048_576, let raw = bytes(Int(length)) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        mutating func skip(_ count: UInt64) -> Bool {
            guard count <= UInt64(data.count - offset) else { return false }
            offset += Int(count)
            return true
        }
    }
}
