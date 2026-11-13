import Foundation
import os

#if os(macOS)
import CoreServices

// MARK: - Detected Workspace Edit

/// Full per-file mutation payload emitted by `WorkspaceChangeTracker` when a
/// shell/script tool call completes.
public struct WorkspaceDetectedEdit: Sendable, Equatable {
    /// Preferred project-aligned absolute path on disk.
    public let path: String
    public let kind: DetectedFileChangeKind
    /// Exact content prior to this command (`nil` when newly created).
    public let beforeContent: String?
    /// Exact content after this command (`nil` when deleted).
    public let afterContent: String?
    /// Anchored hunks for `ThreadFileEdit` persistence and interleaved rendering.
    public let hunks: [PreviewFile.EditHunk]
    /// Compact metadata + unified diff attached directly to `ToolCall.input` for chat UI.
    public let chatChange: DetectedShellFileChange

    public init(
        path: String,
        kind: DetectedFileChangeKind,
        beforeContent: String?,
        afterContent: String?,
        hunks: [PreviewFile.EditHunk],
        chatChange: DetectedShellFileChange
    ) {
        self.path = path
        self.kind = kind
        self.beforeContent = beforeContent
        self.afterContent = afterContent
        self.hunks = hunks
        self.chatChange = chatChange
    }
}

// MARK: - Registry

/// Shared process-wide registry maintaining one `WorkspaceChangeTracker` actor
/// per canonical workspace root directory.
public actor WorkspaceChangeTrackerRegistry {
    public static let shared = WorkspaceChangeTrackerRegistry()

    private var trackersByCanonicalRoot: [String: WorkspaceChangeTracker] = [:]

    public init() {}

    public func tracker(for rootPath: String) -> WorkspaceChangeTracker? {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = trackersByCanonicalRoot[canonical] {
            return existing
        }
        let created = WorkspaceChangeTracker(preferredRootPath: trimmed, canonicalRootPath: canonical)
        trackersByCanonicalRoot[canonical] = created
        return created
    }
}

// MARK: - Per-Workspace Non-Blocking Change Tracker

/// Tracks per-thread file changes caused by shell commands and scripts inside a
/// workspace root without blocking or serializing concurrent agent executions.
///
/// Combines:
/// 1. A rolling content ledger (`lastKnownContent` per canonical file path),
/// 2. Continuous `FSEventStream` (`FileEvents | NoDefer`) + synchronous flush,
/// 3. Git porcelain (`git status --porcelain=v1 -z --untracked-files=all`) or
///    bounded non-git directory mtime sweeps so zero-latency scripts never drop events,
/// 4. Live `ProcessTreeProbe` open-FD sampling when multiple shell spans overlap,
/// 5. `WorkspaceChangeAttribution` multi-signal attribution.
public actor WorkspaceChangeTracker {

    // MARK: - Types

    struct LedgerEntry {
        var content: String?
        var mtime: TimeInterval?
        var fileSize: Int?
    }

    enum DiskFileState {
        case text(content: String, mtime: TimeInterval?, size: Int)
        case absent
        case ignored
    }

    struct StreamRegistration {
        var sessionKey: String
        var cwd: String
        var rootPid: Int32?
    }

    final class FSEventBridge: @unchecked Sendable {
        weak var tracker: WorkspaceChangeTracker?
        init(tracker: WorkspaceChangeTracker) {
            self.tracker = tracker
        }
    }

    // MARK: - Constants

    static let maxTrackedFileBytes = 1_500_000
    static let maxNonGitSeedFiles = 4_000
    static let ignoredDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", "DerivedData", ".build", ".swiftpm",
        "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".venv", "venv",
        "Pods", "Carthage", ".gradle",
    ]
    static let ignoredExtensions: Set<String> = [
        "o", "a", "dylib", "so", "dll", "exe", "pyc", "pyo", "class",
        "d", "dia", "swiftmodule", "swiftdoc", "swiftsourceinfo",
        "swp", "swo", "tmp", "bak", "DS_Store",
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf",
        "mp3", "mp4", "mov", "wav", "zip", "tar", "gz", "xz", "7z",
        "sqlite", "sqlite-wal", "sqlite-shm", "db", "store", "store-wal", "store-shm",
    ]

    // MARK: - State

    public let preferredRootPath: String
    public let canonicalRootPath: String

    let logger = Logger(subsystem: "com.claudework", category: "WorkspaceChangeTracker")
    let fsQueue = DispatchQueue(label: "com.claudework.WorkspaceChangeTracker.fsevents", qos: .userInitiated)

    private var isInitialized = false
    var gitRepoRoot: String?
    var ledger: [String: LedgerEntry] = [:]
    var gitIgnoreCache: [String: Bool] = [:]

    var activeStreams: [UUID: StreamRegistration] = [:]
    /// Keyed by `spanKey(streamId:toolUseId:)`.
    var activeSpans: [String: ActiveShellSpan] = [:]
    /// Paths delivered by `FSEvents` since the last full ledger sync.
    var pendingEventPaths = Set<String>()
    /// Records which `spanId`s were active when an FSEvent arrived for `canonicalPath`.
    var observedSpanIdsByPath: [String: Set<UUID>] = [:]
    /// Records `streamId`s observed holding a writable FD on `canonicalPath`.
    var writerStreamsByPath: [String: Set<UUID>] = [:]
    var probeSamplerTask: Task<Void, Never>?

    var fsEventStream: FSEventStreamRef?
    var fsEventBridgePtr: UnsafeMutableRawPointer?

    // MARK: - Init

    public init(preferredRootPath: String, canonicalRootPath: String) {
        self.preferredRootPath = (preferredRootPath as NSString).standardizingPath
        self.canonicalRootPath = canonicalRootPath
    }

    // MARK: - Stream Lifecycle

    /// Registers an active agent turn stream. When transitioning from 0 → 1
    /// active streams, refreshes the baseline ledger so pre-turn external edits
    /// are never attributed to the upcoming turn.
    public func streamDidStart(
        streamId: UUID,
        sessionKey: String,
        cwd: String,
        rootPid: Int32? = nil
    ) async {
        let wasIdle = activeStreams.isEmpty && activeSpans.isEmpty
        await ensureInitialized()
        if wasIdle {
            await syncIdleWorkspaceToLedger()
        }
        let resolvedCwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        activeStreams[streamId] = StreamRegistration(
            sessionKey: sessionKey,
            cwd: resolvedCwd,
            rootPid: rootPid
        )
    }

    public func updateStreamRootPid(streamId: UUID, rootPid: Int32?) {
        guard rootPid != nil else { return }
        activeStreams[streamId]?.rootPid = rootPid
        for (key, var span) in activeSpans where span.streamId == streamId {
            span = ActiveShellSpan(
                spanId: span.spanId,
                sessionKey: span.sessionKey,
                streamId: span.streamId,
                toolUseId: span.toolUseId,
                command: span.command,
                cwd: span.cwd,
                disposition: span.disposition,
                rootPid: rootPid,
                startedAt: span.startedAt,
                endedAt: span.endedAt,
                candidateTokens: span.candidateTokens
            )
            activeSpans[key] = span
        }
        updateProbeSamplerIfNeeded()
    }

    public func renameSession(from oldKey: String, to newKey: String) {
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else { return }
        for (id, var reg) in activeStreams where reg.sessionKey == oldKey {
            reg.sessionKey = newKey
            activeStreams[id] = reg
        }
        for (key, span) in activeSpans where span.sessionKey == oldKey {
            activeSpans[key] = ActiveShellSpan(
                spanId: span.spanId,
                sessionKey: newKey,
                streamId: span.streamId,
                toolUseId: span.toolUseId,
                command: span.command,
                cwd: span.cwd,
                disposition: span.disposition,
                rootPid: span.rootPid,
                startedAt: span.startedAt,
                endedAt: span.endedAt,
                candidateTokens: span.candidateTokens
            )
        }
    }

    public func streamDidEnd(streamId: UUID) {
        activeStreams.removeValue(forKey: streamId)
        for (key, span) in Array(activeSpans) where span.streamId == streamId {
            activeSpans.removeValue(forKey: key)
        }
        updateProbeSamplerIfNeeded()
        if activeStreams.isEmpty, activeSpans.isEmpty {
            stopFSEventsIfIdle()
        }
    }

    // MARK: - Structured Edit Sync

    /// Updates the rolling ledger when a structured `Edit`/`MultiEdit`/`Write`
    /// tool call modifies `path` so a subsequent `Bash` command in the same turn
    /// only sees deltas beyond the structured edit.
    public func recordStructuredEdit(path: String, modifiedContent: String?) async {
        await ensureInitialized()
        let canonical = toCanonicalPath(path)
        guard isInsideWorkspace(canonical) else { return }
        if let modifiedContent {
            let attrs = try? FileManager.default.attributesOfItem(atPath: canonical)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
            let size = attrs?[.size] as? Int
            ledger[canonical] = LedgerEntry(content: modifiedContent, mtime: mtime, fileSize: size)
        } else {
            refreshLedgerEntryFromDisk(canonicalPath: canonical)
        }
        pendingEventPaths.remove(canonical)
    }

    // MARK: - Shell Span Lifecycle

    /// Opens or enriches an active shell execution span (`toolCallStarted` /
    /// `toolCallInput` / `assistant(toolUse)`). Never blocks command execution.
    public func upsertShellSpan(
        streamId: UUID,
        sessionKey: String,
        toolUseId: String,
        command: String?,
        cwd: String? = nil,
        rootPid: Int32? = nil
    ) async {
        await ensureInitialized()
        startFSEventsIfNeeded()

        let key = spanKey(streamId: streamId, toolUseId: toolUseId)
        let resolvedCwd = cwd.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        } ?? activeStreams[streamId]?.cwd ?? canonicalRootPath
        let resolvedPid = rootPid ?? activeStreams[streamId]?.rootPid
        let cmdString = command ?? activeSpans[key]?.command ?? ""

        let extraScripts = loadReferencedScripts(for: cmdString, cwd: resolvedCwd)
        let disposition = cmdString.isEmpty
            ? .mutatingOrUnknown
            : ShellCommandClassifier.classify(cmdString)
        let tokens = ShellCommandClassifier.extractCandidatePathTokens(
            from: cmdString,
            extraScriptContents: extraScripts
        )

        if let existing = activeSpans[key] {
            var mergedTokens = existing.candidateTokens
            mergedTokens.formUnion(tokens)
            activeSpans[key] = ActiveShellSpan(
                spanId: existing.spanId,
                sessionKey: sessionKey,
                streamId: streamId,
                toolUseId: toolUseId,
                command: cmdString.isEmpty ? existing.command : cmdString,
                cwd: resolvedCwd,
                disposition: cmdString.isEmpty ? existing.disposition : disposition,
                rootPid: resolvedPid ?? existing.rootPid,
                startedAt: existing.startedAt,
                endedAt: nil,
                candidateTokens: mergedTokens
            )
        } else {
            // If no other shell span is currently active, flush FSEvents first so
            // any pre-span idle notifications don't get tagged with this new spanId.
            if activeSpans.isEmpty {
                await flushFSEvents()
            }
            activeSpans[key] = ActiveShellSpan(
                sessionKey: sessionKey,
                streamId: streamId,
                toolUseId: toolUseId,
                command: cmdString,
                cwd: resolvedCwd,
                disposition: disposition,
                rootPid: resolvedPid,
                startedAt: Date(),
                candidateTokens: tokens
            )
        }

        updateProbeSamplerIfNeeded()
    }

    /// Completes a shell execution span on `tool_result`, diffs candidate
    /// workspace files against the rolling ledger, resolves concurrent multi-thread
    /// ownership, advances the ledger for owned deltas, and returns the exact
    /// per-file edits attributed to this tool call.
    public func endShellSpan(
        streamId: UUID,
        sessionKey: String,
        toolUseId: String,
        fallbackCommand: String? = nil,
        cwd: String? = nil,
        rootPid: Int32? = nil
    ) async -> [WorkspaceDetectedEdit] {
        await ensureInitialized()

        let key = spanKey(streamId: streamId, toolUseId: toolUseId)
        let resolvedCwd = cwd.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        } ?? activeStreams[streamId]?.cwd ?? canonicalRootPath
        let resolvedPid = rootPid ?? activeStreams[streamId]?.rootPid

        var completingSpan: ActiveShellSpan
        if var existing = activeSpans.removeValue(forKey: key) {
            if existing.command.isEmpty, let fallbackCommand, !fallbackCommand.isEmpty {
                let scripts = loadReferencedScripts(for: fallbackCommand, cwd: resolvedCwd)
                existing = ActiveShellSpan(
                    spanId: existing.spanId,
                    sessionKey: sessionKey,
                    streamId: streamId,
                    toolUseId: toolUseId,
                    command: fallbackCommand,
                    cwd: resolvedCwd,
                    disposition: ShellCommandClassifier.classify(fallbackCommand),
                    rootPid: resolvedPid ?? existing.rootPid,
                    startedAt: existing.startedAt,
                    endedAt: Date(),
                    candidateTokens: ShellCommandClassifier.extractCandidatePathTokens(
                        from: fallbackCommand,
                        extraScriptContents: scripts
                    )
                )
            } else {
                existing.endedAt = Date()
            }
            completingSpan = existing
        } else {
            let cmd = fallbackCommand ?? ""
            let scripts = loadReferencedScripts(for: cmd, cwd: resolvedCwd)
            completingSpan = ActiveShellSpan(
                sessionKey: sessionKey,
                streamId: streamId,
                toolUseId: toolUseId,
                command: cmd,
                cwd: resolvedCwd,
                disposition: cmd.isEmpty ? .mutatingOrUnknown : ShellCommandClassifier.classify(cmd),
                rootPid: resolvedPid,
                startedAt: Date(),
                endedAt: Date(),
                candidateTokens: ShellCommandClassifier.extractCandidatePathTokens(
                    from: cmd,
                    extraScriptContents: scripts
                )
            )
        }

        updateProbeSamplerIfNeeded()

        // Fast-path skip: if this command is strictly readOnly (`ls`, `rg`, `git status`),
        // no FSEvents arrived, and we aren't holding any write FDs, avoid spawning `git status`
        // on every single `rg` / `ls` call!
        await flushFSEvents()
        if completingSpan.disposition == .readOnly,
           pendingEventPaths.isEmpty,
           writerStreamsByPath.values.allSatisfy({ !$0.contains(streamId) }) {
            return []
        }

        // Collect all candidate changed paths from BOTH FSEvents AND Git porcelain / mtime scan.
        var candidatesToInspect = pendingEventPaths
        let sweptPaths = await discoverModifiedPathsFromWorkspace()
        candidatesToInspect.formUnion(sweptPaths)

        guard !candidatesToInspect.isEmpty else { return [] }

        // Filter out gitignored paths among raw FSEvents candidates.
        let unignoredCandidates = await filterOutGitIgnored(paths: candidatesToInspect)
        guard !unignoredCandidates.isEmpty else {
            pendingEventPaths.subtract(candidatesToInspect)
            return []
        }

        let allCandidateSpans = [completingSpan] + Array(activeSpans.values)
        var detectedEdits: [WorkspaceDetectedEdit] = []

        for canonicalPath in unignoredCandidates.sorted() {
            guard shouldTrackPathStructure(canonicalPath) else {
                pendingEventPaths.remove(canonicalPath)
                observedSpanIdsByPath.removeValue(forKey: canonicalPath)
                writerStreamsByPath.removeValue(forKey: canonicalPath)
                continue
            }

            let diskState = readDiskFileState(at: canonicalPath)
            if case .ignored = diskState {
                pendingEventPaths.remove(canonicalPath)
                continue
            }

            let afterContent: String?
            let afterMtime: TimeInterval?
            let afterSize: Int?
            switch diskState {
            case .text(let text, let mtime, let size):
                afterContent = text
                afterMtime = mtime
                afterSize = size
            case .absent:
                afterContent = nil
                afterMtime = nil
                afterSize = nil
            case .ignored:
                continue
            }

            let beforeContent = await resolveBaselineContent(for: canonicalPath)
            guard let extracted = SnapshotDiffExtractor.extract(before: beforeContent, after: afterContent) else {
                // Content matches baseline (e.g. `touch` on existing file or reverted write).
                ledger[canonicalPath] = LedgerEntry(content: afterContent, mtime: afterMtime, fileSize: afterSize)
                pendingEventPaths.remove(canonicalPath)
                observedSpanIdsByPath.removeValue(forKey: canonicalPath)
                writerStreamsByPath.removeValue(forKey: canonicalPath)
                continue
            }

            let writers = writerStreamsByPath[canonicalPath] ?? []
            let observers = observedSpanIdsByPath[canonicalPath] ?? []
            guard let attribution = WorkspaceChangeAttribution.resolve(
                filePath: canonicalPath,
                rootPath: canonicalRootPath,
                candidates: allCandidateSpans,
                writerStreamIds: writers,
                observedBySpanIds: observers
            ) else {
                // External user/IDE edit while only read-only agent tools were active:
                // advance ledger silently so no future agent command claims it.
                ledger[canonicalPath] = LedgerEntry(content: afterContent, mtime: afterMtime, fileSize: afterSize)
                pendingEventPaths.remove(canonicalPath)
                observedSpanIdsByPath.removeValue(forKey: canonicalPath)
                writerStreamsByPath.removeValue(forKey: canonicalPath)
                continue
            }

            if attribution.winningSpan.spanId == completingSpan.spanId {
                // Owned by this completing span: advance ledger and emit!
                ledger[canonicalPath] = LedgerEntry(content: afterContent, mtime: afterMtime, fileSize: afterSize)
                pendingEventPaths.remove(canonicalPath)
                observedSpanIdsByPath.removeValue(forKey: canonicalPath)
                writerStreamsByPath.removeValue(forKey: canonicalPath)

                let preferredPath = toPreferredPath(canonicalPath)
                let chatChange = DetectedShellFileChange(
                    path: preferredPath,
                    kind: extracted.kind,
                    addedLines: extracted.addedLines,
                    removedLines: extracted.removedLines,
                    diff: extracted.unifiedDiff,
                    isAmbiguous: attribution.isAmbiguous
                )
                detectedEdits.append(WorkspaceDetectedEdit(
                    path: preferredPath,
                    kind: extracted.kind,
                    beforeContent: beforeContent,
                    afterContent: afterContent,
                    hunks: extracted.editHunks,
                    chatChange: chatChange
                ))
            } else {
                // Owned by another STILL-ACTIVE span in another thread: leave
                // `ledger[canonicalPath]` at its pre-edit state and keep the path
                // queued in `pendingEventPaths` so the owning span collects its
                // full cumulative delta when it finishes.
                pendingEventPaths.insert(canonicalPath)
            }
        }

        return detectedEdits
    }

    // MARK: - Initialization & Baseline Seeding

    private func ensureInitialized() async {
        guard !isInitialized else { return }
        isInitialized = true

        if let topLevel = await GitHelper.run(["rev-parse", "--show-toplevel"], at: canonicalRootPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !topLevel.isEmpty {
            gitRepoRoot = URL(fileURLWithPath: topLevel).resolvingSymlinksInPath().standardizedFileURL.path
        }

        await syncIdleWorkspaceToLedger()
        startFSEventsIfNeeded()
    }

    /// Absorbs any pre-existing dirty/untracked files into `ledger` when no
    /// agent streams or spans are running.
    private func syncIdleWorkspaceToLedger() async {
        await flushFSEvents()
        pendingEventPaths.removeAll()
        observedSpanIdsByPath.removeAll()
        writerStreamsByPath.removeAll()

        if gitRepoRoot != nil {
            let dirtyPaths = await gitPorcelainPaths()
            // If a previously-dirty ledger entry is no longer dirty in `git status`,
            // drop its stale override so it falls back to clean `HEAD`/`:0:` again!
            let dirtySet = Set(dirtyPaths)
            for existingKey in Array(ledger.keys) where !dirtySet.contains(existingKey) {
                ledger.removeValue(forKey: existingKey)
            }
            for canonicalPath in dirtyPaths where shouldTrackPathStructure(canonicalPath) {
                refreshLedgerEntryFromDisk(canonicalPath: canonicalPath)
            }
        } else {
            ledger.removeAll(keepingCapacity: true)
            for canonicalPath in scanNonGitTextFiles() {
                refreshLedgerEntryFromDisk(canonicalPath: canonicalPath)
            }
        }
    }

    func refreshLedgerEntryFromDisk(canonicalPath: String) {
        switch readDiskFileState(at: canonicalPath) {
        case .text(let content, let mtime, let size):
            ledger[canonicalPath] = LedgerEntry(content: content, mtime: mtime, fileSize: size)
        case .absent:
            ledger[canonicalPath] = LedgerEntry(content: nil, mtime: nil, fileSize: nil)
        case .ignored:
            ledger.removeValue(forKey: canonicalPath)
        }
    }

    /// Resolves the "before" content of `canonicalPath` prior to the current span:
    /// 1. `ledger[canonicalPath]` if already tracked in the rolling ledger,
    /// 2. Git index (`:0:<rel>`) or `HEAD:<rel>` if clean in Git prior to this span,
    /// 3. `nil` if newly created.
    private func resolveBaselineContent(for canonicalPath: String) async -> String? {
        if let entry = ledger[canonicalPath] {
            return entry.content
        }
        guard let gitRoot = gitRepoRoot else {
            return nil
        }
        let prefix = gitRoot.hasSuffix("/") ? gitRoot : gitRoot + "/"
        guard canonicalPath.hasPrefix(prefix) else { return nil }
        let repoRelPath = String(canonicalPath.dropFirst(prefix.count))
        if let indexContent = await GitHelper.run(["show", ":0:\(repoRelPath)"], at: gitRoot) {
            return indexContent
        }
        if let headContent = await GitHelper.run(["show", "HEAD:\(repoRelPath)"], at: gitRoot) {
            return headContent
        }
        return nil
    }

    // MARK: - Workspace Delta Discovery

    private func discoverModifiedPathsFromWorkspace() async -> Set<String> {
        if gitRepoRoot != nil {
            var paths = Set(await gitPorcelainPaths())
            // Also include any file in `ledger` that might have been restored back
            // to clean HEAD (so `git status` no longer lists it, even though it
            // changed relative to `ledger` during `git checkout -- file`!).
            for (path, entry) in ledger {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let exists = attrs != nil
                if !exists, entry.content != nil {
                    paths.insert(path)
                } else if exists, entry.content == nil {
                    paths.insert(path)
                } else if let attrs {
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
                    let size = attrs[.size] as? Int
                    if mtime != entry.mtime || size != entry.fileSize {
                        paths.insert(path)
                    }
                }
            }
            return paths
        } else {
            var changed = Set<String>()
            let currentFiles = Set(scanNonGitTextFiles())
            for path in currentFiles {
                guard let entry = ledger[path] else {
                    changed.insert(path)
                    continue
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
                let size = attrs?[.size] as? Int
                if mtime != entry.mtime || size != entry.fileSize {
                    changed.insert(path)
                }
            }
            for (path, entry) in ledger where entry.content != nil && !currentFiles.contains(path) {
                if !FileManager.default.fileExists(atPath: path) {
                    changed.insert(path)
                }
            }
            return changed
        }
    }

    private func gitPorcelainPaths() async -> [String] {
        guard let gitRoot = gitRepoRoot,
              let raw = await GitHelper.run(
                  ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", canonicalRootPath],
                  at: gitRoot
              ) else {
            return []
        }

        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var paths: [String] = []
        var idx = 0
        while idx < tokens.count {
            let entry = tokens[idx]
            idx += 1
            guard entry.count >= 4 else { continue }
            let chars = Array(entry)
            let x = chars[0]
            let y = chars[1]
            let relPath = String(entry.dropFirst(3))
            let absNew = URL(fileURLWithPath: (gitRoot as NSString).appendingPathComponent(relPath))
                .resolvingSymlinksInPath().standardizedFileURL.path
            if isInsideWorkspace(absNew) {
                paths.append(absNew)
            }
            // Rename or copy in porcelain `-z` has a second NUL token for the original path!
            if x == "R" || y == "R" || x == "C" || y == "C", idx < tokens.count {
                let origRel = tokens[idx]
                idx += 1
                if !origRel.isEmpty {
                    let absOrig = URL(fileURLWithPath: (gitRoot as NSString).appendingPathComponent(origRel))
                        .resolvingSymlinksInPath().standardizedFileURL.path
                    if isInsideWorkspace(absOrig) {
                        paths.append(absOrig)
                    }
                }
            }
        }
        return paths
    }

    private func scanNonGitTextFiles() -> [String] {
        let rootURL = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if Self.ignoredDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard shouldTrackPathStructure(canonical) else { continue }
            results.append(canonical)
            if results.count >= Self.maxNonGitSeedFiles {
                break
            }
        }
        return results
    }
}
#endif
