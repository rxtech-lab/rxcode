import Foundation
import os

#if os(macOS)
import CoreServices

extension WorkspaceChangeTracker {

    // MARK: - Path & File Filtering

    func isInsideWorkspace(_ canonicalPath: String) -> Bool {
        canonicalPath.hasPrefix(canonicalRootPath + "/")
    }

    func shouldTrackPathStructure(_ canonicalPath: String) -> Bool {
        guard isInsideWorkspace(canonicalPath) else { return false }
        if canonicalPath.hasSuffix(".md"),
           canonicalPath.contains("/.claude/plans/") || canonicalPath.contains("/claude/plans/") {
            return false
        }

        let relPath = String(canonicalPath.dropFirst(canonicalRootPath.count + 1))
        let components = relPath.split(separator: "/").map(String.init)
        guard let fileName = components.last, !fileName.isEmpty else { return false }

        for segment in components.dropLast() where Self.ignoredDirectoryNames.contains(segment) {
            return false
        }

        if fileName == ".DS_Store" || fileName == "Thumbs.db"
            || fileName.hasPrefix(".#") || fileName.hasPrefix(".!")
            || fileName.hasSuffix("~") {
            return false
        }
        // Atomic write temp files like `.file.swift.tmp.12345`
        if fileName.hasPrefix("."), fileName.contains(".tmp.") {
            return false
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty, Self.ignoredExtensions.contains(ext) {
            return false
        }
        return true
    }

    func filterOutGitIgnored(paths: Set<String>) async -> Set<String> {
        guard let gitRoot = gitRepoRoot, !paths.isEmpty else { return paths }

        var uncached: [String] = []
        for path in paths where gitIgnoreCache[path] == nil && ledger[path] == nil {
            uncached.append(path)
        }

        if !uncached.isEmpty {
            let ignored = await runGitCheckIgnore(paths: uncached, gitRoot: gitRoot)
            for path in uncached {
                gitIgnoreCache[path] = ignored.contains(path)
            }
        }

        return paths.filter { path in
            if ledger[path] != nil { return true }
            return gitIgnoreCache[path] != true
        }
    }

    private func runGitCheckIgnore(paths: [String], gitRoot: String) async -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ignore", "-z", "--stdin"]
        process.currentDirectoryURL = URL(fileURLWithPath: gitRoot)

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let payload = paths.joined(separator: "\0") + "\0"
        if let data = payload.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inPipe.fileHandleForWriting.close()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outString = String(data: outData, encoding: .utf8), !outString.isEmpty else {
            return []
        }
        let matched = outString
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().standardizedFileURL.path }
        return Set(matched)
    }

    func readDiskFileState(at canonicalPath: String) -> DiskFileState {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDir) else {
            return .absent
        }
        if isDir.boolValue {
            return .ignored
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: canonicalPath) else {
            return .absent
        }
        if let fileType = attrs[.type] as? FileAttributeType,
           fileType != .typeRegular && fileType != .typeSymbolicLink {
            return .ignored
        }
        let size = (attrs[.size] as? Int) ?? 0
        if size > Self.maxTrackedFileBytes {
            return .ignored
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: canonicalPath), options: [.mappedIfSafe]) else {
            return .ignored
        }
        if data.prefix(8_192).contains(0) {
            return .ignored
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .ignored
        }
        return .text(content: text, mtime: mtime, size: size)
    }

    func loadReferencedScripts(for command: String, cwd: String) -> [String] {
        guard !command.isEmpty else { return [] }
        let scriptPaths = ShellCommandClassifier.extractReferencedScriptPaths(from: command, cwd: cwd)
        var contents: [String] = []
        for path in scriptPaths.prefix(4) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int,
                  size > 0, size <= 128_000,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            contents.append(text)
        }
        return contents
    }

    // MARK: - FSEvents & Live Process Probe

    func startFSEventsIfNeeded() {
        guard fsEventStream == nil else { return }
        guard FileManager.default.fileExists(atPath: canonicalRootPath) else { return }

        let bridge = FSEventBridge(tracker: self)
        let info = Unmanaged.passRetained(bridge).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, infoPtr, numEvents, eventPaths, _, _ in
            guard let infoPtr, numEvents > 0 else { return }
            let bridge = Unmanaged<FSEventBridge>.fromOpaque(infoPtr).takeUnretainedValue()
            guard let tracker = bridge.tracker else { return }

            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let rawPaths = cfArray as? [String], !rawPaths.isEmpty else { return }
            bridge.append(rawPaths)
            Task { await tracker.drainFSEvents(from: bridge) }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [canonicalRootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.02,
            flags
        ) else {
            Unmanaged<FSEventBridge>.fromOpaque(info).release()
            logger.error("FSEventStreamCreate failed for \(self.canonicalRootPath, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, fsQueue)
        FSEventStreamStart(stream)
        fsEventStream = stream
        fsEventBridgePtr = info
    }

    func flushFSEvents() async {
        guard let stream = fsEventStream, let bridgePtr = fsEventBridgePtr else { return }
        let bridge = Unmanaged<FSEventBridge>.fromOpaque(bridgePtr).takeUnretainedValue()
        let nonisolatedStream = UnsafeSendableFSEventStream(stream: stream)
        fsEventFlushCount += 1
        defer {
            fsEventFlushCount -= 1
            if activeStreams.isEmpty, activeSpans.isEmpty {
                stopFSEventsIfIdle()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Flush waits for callbacks on fsQueue, so it must run elsewhere.
            DispatchQueue.global(qos: .userInitiated).async {
                FSEventStreamFlushSync(nonisolatedStream.stream)
                continuation.resume()
            }
        }
        // Callback tasks may still be waiting to enter this actor. Consume their
        // buffered paths before the caller reads or resets the ledger.
        drainFSEvents(from: bridge)
    }

    func drainFSEvents(from bridge: FSEventBridge) {
        let paths = bridge.takePaths()
        if !paths.isEmpty {
            ingestFSEventPaths(paths)
        }
    }

    func stopFSEventsIfIdle() {
        probeSamplerTask?.cancel()
        probeSamplerTask = nil
        // An awaiting flush still owns the active stream and callback context.
        guard fsEventFlushCount == 0 else { return }
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
        if let ptr = fsEventBridgePtr {
            Unmanaged<FSEventBridge>.fromOpaque(ptr).release()
            fsEventBridgePtr = nil
        }
    }

    func ingestFSEventPaths(_ rawPaths: [String]) {
        let currentSpanIds = Set(activeSpans.values.map(\.spanId))
        let isCompletelyIdle = activeStreams.isEmpty && activeSpans.isEmpty

        for raw in rawPaths {
            let canonical = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
            guard shouldTrackPathStructure(canonical) else { continue }
            if isCompletelyIdle {
                // Keep baseline fresh while no agent turns are active.
                refreshLedgerEntryFromDisk(canonicalPath: canonical)
            } else {
                pendingEventPaths.insert(canonical)
                if !currentSpanIds.isEmpty {
                    observedSpanIdsByPath[canonical, default: []].formUnion(currentSpanIds)
                }
            }
        }
    }

    /// Runs a lightweight 25ms `ProcessTreeProbe` sampler ONLY while ≥ 2 shell
    /// spans from distinct sessions overlap concurrently.
    func updateProbeSamplerIfNeeded() {
        let distinctSessions = Set(activeSpans.values.map(\.sessionKey))
        let needsSampler = distinctSessions.count >= 2 && activeStreams.values.contains { ($0.rootPid ?? 0) > 1 }
        if needsSampler {
            guard probeSamplerTask == nil else { return }
            probeSamplerTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.sampleOpenWritableFilesOnce()
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        } else {
            probeSamplerTask?.cancel()
            probeSamplerTask = nil
        }
    }

    private func sampleOpenWritableFilesOnce() {
        var pidsByStream: [UUID: Int32] = [:]
        for span in activeSpans.values {
            if let pid = span.rootPid ?? activeStreams[span.streamId]?.rootPid, pid > 1 {
                pidsByStream[span.streamId] = pid
            }
        }
        guard !pidsByStream.isEmpty else { return }
        let sampled = ProcessTreeProbe.sampleWritableOpenFiles(
            rootPidsByStream: pidsByStream,
            canonicalRootPrefix: canonicalRootPath
        )
        for (path, streamIds) in sampled {
            writerStreamsByPath[path, default: []].formUnion(streamIds)
        }
    }

    // MARK: - Path Mapping Helpers

    func spanKey(streamId: UUID, toolUseId: String) -> String {
        "\(streamId.uuidString)|\(toolUseId)"
    }

    func toCanonicalPath(_ path: String) -> String {
        let expanded: String
        if path.hasPrefix("/") {
            expanded = path
        } else {
            expanded = (canonicalRootPath as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func toPreferredPath(_ canonicalPath: String) -> String {
        guard preferredRootPath != canonicalRootPath,
              canonicalPath.hasPrefix(canonicalRootPath + "/") else {
            return canonicalPath
        }
        let suffix = String(canonicalPath.dropFirst(canonicalRootPath.count))
        return preferredRootPath + suffix
    }
}

private struct UnsafeSendableFSEventStream: @unchecked Sendable {
    let stream: FSEventStreamRef
}
#endif
