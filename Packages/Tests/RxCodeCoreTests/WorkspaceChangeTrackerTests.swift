import Foundation
import Testing
@testable import RxCodeCore

@Suite("Workspace shell change tracking & attribution")
struct WorkspaceChangeTrackerTests {

    // MARK: - SnapshotDiffExtractor

    @Test("SnapshotDiffExtractor extracts created, modified, deleted, and no-op diffs")
    func snapshotDiffExtractorCoversAllKinds() throws {
        #expect(SnapshotDiffExtractor.extract(before: nil, after: nil) == nil)
        #expect(SnapshotDiffExtractor.extract(before: "same\n", after: "same\n") == nil)

        let created = try #require(SnapshotDiffExtractor.extract(before: nil, after: "alpha\nbeta\n"))
        #expect(created.kind == .created)
        #expect(created.addedLines == 2)
        #expect(created.removedLines == 0)
        #expect(created.unifiedDiff.contains("+alpha"))
        #expect(created.editHunks == [PreviewFile.EditHunk(oldString: "", newString: "alpha\nbeta")])

        let modified = try #require(SnapshotDiffExtractor.extract(
            before: "line1\nline2\nline3\nline4\n",
            after: "line1\nLINE_TWO\nline3\nline4\n"
        ))
        #expect(modified.kind == .modified)
        #expect(modified.addedLines == 1)
        #expect(modified.removedLines == 1)
        #expect(modified.unifiedDiff.contains("-line2"))
        #expect(modified.unifiedDiff.contains("+LINE_TWO"))
        #expect(!modified.editHunks.isEmpty)

        let deleted = try #require(SnapshotDiffExtractor.extract(before: "gone1\ngone2\n", after: nil))
        #expect(deleted.kind == .deleted)
        #expect(deleted.addedLines == 0)
        #expect(deleted.removedLines == 2)
        #expect(deleted.unifiedDiff.contains("-gone1"))
        #expect(deleted.editHunks == [PreviewFile.EditHunk(oldString: "gone1\ngone2", newString: "")])
    }

    // MARK: - ShellCommandClassifier

    @Test("ShellCommandClassifier distinguishes read-only, build/test, and mutating commands")
    func shellCommandClassifierDisposition() {
        #expect(ShellCommandClassifier.classify("ls -la Sources") == .readOnly)
        #expect(ShellCommandClassifier.classify("rg -n WorkspaceChangeTracker Packages/") == .readOnly)
        #expect(ShellCommandClassifier.classify("git status --short && git diff HEAD") == .readOnly)
        #expect(ShellCommandClassifier.classify("git rev-list --count HEAD") == .readOnly)

        #expect(ShellCommandClassifier.classify("swift test --package-path Packages") == .buildOrTest)
        #expect(ShellCommandClassifier.classify("xcodebuild -scheme RxCode build") == .buildOrTest)
        #expect(ShellCommandClassifier.classify("pytest tests/unit") == .buildOrTest)

        #expect(ShellCommandClassifier.classify("python3 -c \"open('Sources/Foo.swift','w').write('x')\"") == .mutatingOrUnknown)
        #expect(ShellCommandClassifier.classify("sed -i '' 's/old/new/g' Sources/App.swift") == .mutatingOrUnknown)
        #expect(ShellCommandClassifier.classify("cat Sources/A.swift > Sources/B.swift") == .mutatingOrUnknown)
        #expect(ShellCommandClassifier.classify("rm -f Sources/Obsolete.swift") == .mutatingOrUnknown)
    }

    @Test("ShellCommandClassifier extracts file tokens from inline commands and referenced scripts")
    func shellCommandClassifierExtractsCandidateTokens() {
        let cmd = "python3 /tmp/refactor_job.py --dry-run=false"
        let scriptRefs = ShellCommandClassifier.extractReferencedScriptPaths(from: cmd, cwd: "/repo")
        #expect(scriptRefs.contains("/tmp/refactor_job.py"))

        let scriptBody = """
        from pathlib import Path
        target = Path("Packages/Sources/Feature/WidgetService.swift")
        target.write_text("struct WidgetService {}\\n")
        """
        let tokens = ShellCommandClassifier.extractCandidatePathTokens(
            from: cmd,
            extraScriptContents: [scriptBody]
        )
        #expect(tokens.contains("packages/sources/feature/widgetservice.swift"))
        #expect(tokens.contains("feature/widgetservice.swift"))
        #expect(tokens.contains("widgetservice.swift"))
        #expect(tokens.contains("widgetservice"))
    }

    // MARK: - WorkspaceChangeAttribution

    @Test("WorkspaceChangeAttribution resolves concurrent spans via tokens, FD proof, and read-only rejection")
    func attributionResolvesConcurrentSpans() throws {
        let streamA = UUID()
        let streamB = UUID()
        let now = Date()

        let spanA = ActiveShellSpan(
            sessionKey: "thread-A",
            streamId: streamA,
            toolUseId: "tool-A",
            command: "python3 -c \"open('Sources/Alpha.swift', 'w').write('a')\"",
            cwd: "/repo",
            disposition: .mutatingOrUnknown,
            startedAt: now,
            candidateTokens: ShellCommandClassifier.extractCandidatePathTokens(
                from: "python3 -c \"open('Sources/Alpha.swift', 'w').write('a')\""
            )
        )
        let spanB = ActiveShellSpan(
            sessionKey: "thread-B",
            streamId: streamB,
            toolUseId: "tool-B",
            command: "node -e \"fs.writeFileSync('Sources/Beta.swift', 'b')\"",
            cwd: "/repo",
            disposition: .mutatingOrUnknown,
            startedAt: now,
            candidateTokens: ShellCommandClassifier.extractCandidatePathTokens(
                from: "node -e \"fs.writeFileSync('Sources/Beta.swift', 'b')\""
            )
        )

        let resolvedAlpha = try #require(WorkspaceChangeAttribution.resolve(
            filePath: "/repo/Sources/Alpha.swift",
            rootPath: "/repo",
            candidates: [spanA, spanB]
        ))
        #expect(resolvedAlpha.winningSpan.sessionKey == "thread-A")
        #expect(!resolvedAlpha.isAmbiguous)

        let resolvedBeta = try #require(WorkspaceChangeAttribution.resolve(
            filePath: "/repo/Sources/Beta.swift",
            rootPath: "/repo",
            candidates: [spanA, spanB]
        ))
        #expect(resolvedBeta.winningSpan.sessionKey == "thread-B")
        #expect(!resolvedBeta.isAmbiguous)

        // Kernel open-writable-FD proof overrides everything deterministically.
        let fdOverride = try #require(WorkspaceChangeAttribution.resolve(
            filePath: "/repo/Sources/Unmentioned.swift",
            rootPath: "/repo",
            candidates: [spanA, spanB],
            writerStreamIds: [streamB]
        ))
        #expect(fdOverride.winningSpan.sessionKey == "thread-B")
        #expect(!fdOverride.isAmbiguous)

        // Read-only span without FD write proof never claims external user edits.
        let readOnlySpan = ActiveShellSpan(
            sessionKey: "thread-RO",
            streamId: UUID(),
            toolUseId: "tool-RO",
            command: "rg -n Pattern Sources/",
            cwd: "/repo",
            disposition: .readOnly,
            startedAt: now
        )
        #expect(WorkspaceChangeAttribution.resolve(
            filePath: "/repo/Sources/UserSavedInXcode.swift",
            rootPath: "/repo",
            candidates: [readOnlySpan]
        ) == nil)

        // Exact tie across two distinct sessions marks `isAmbiguous == true`.
        let opaqueA = ActiveShellSpan(
            spanId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionKey: "s1",
            streamId: streamA,
            toolUseId: "u1",
            command: "make generate",
            cwd: "/repo",
            disposition: .mutatingOrUnknown,
            startedAt: now,
            endedAt: now.addingTimeInterval(1.0)
        )
        let opaqueB = ActiveShellSpan(
            spanId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sessionKey: "s2",
            streamId: streamB,
            toolUseId: "u2",
            command: "make generate",
            cwd: "/repo",
            disposition: .mutatingOrUnknown,
            startedAt: now,
            endedAt: now.addingTimeInterval(1.0)
        )
        let tied = try #require(WorkspaceChangeAttribution.resolve(
            filePath: "/repo/Sources/Generated.swift",
            rootPath: "/repo",
            candidates: [opaqueA, opaqueB]
        ))
        #expect(tied.isAmbiguous)
    }

    // MARK: - ToolCall & ChatMessage Helpers

    @Test("ToolCall round-trips detected shell changes and strips internal keys from displayInput")
    func toolCallDetectedChangesRoundTripAndDisplayInput() {
        var call = ToolCall(
            id: "exec-1",
            name: "exec_command",
            input: [
                "cmd": .array([.string("bash"), .string("-lc"), .string("python3 patch.py")]),
                ToolCall.acpKindInputKey: .string("execute"),
            ]
        )
        #expect(call.isShellExecutionTool)
        #expect(call.shellCommandString == "python3 patch.py")

        let change = DetectedShellFileChange(
            path: "/repo/Sources/Item.swift",
            kind: .modified,
            addedLines: 3,
            removedLines: 1,
            diff: "@@ -1,2 +1,4 @@\n-let x = 1\n+let x = 2\n+let y = 3\n+let z = 4",
            isAmbiguous: true
        )
        call.setDetectedShellFileChanges([change])
        #expect(call.detectedShellFileChanges == [change])
        #expect(call.displayInput[ToolCall.detectedFileChangesInputKey] == nil)
        #expect(call.displayInput[ToolCall.acpKindInputKey] == nil)
        #expect(call.displayInput["cmd"] != nil)

        // Empty-stdout shell command must NOT be pruned from ChatMessage.blocks!
        var message = ChatMessage(role: .assistant, blocks: [.toolCall(call)])
        message.setToolResult(id: "exec-1", result: "", isError: false)
        let retainedTools = message.blocks.compactMap(\.toolCall)
        #expect(retainedTools.count == 1)
        #expect(retainedTools.first?.result == "")
    }

    // MARK: - Real Git Workspace Integration Tests

    #if os(macOS)
    @Test("WorkspaceChangeTracker detects Python/shell create, modify, delete and ignores pre-existing dirty files")
    func trackerDetectsShellCreateModifyDeleteAndIgnoresPreExistingDirty() async throws {
        let repoURL = try makeTemporaryGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let trackedPath = repoURL.appendingPathComponent("Sources/Existing.swift").path
        let preDirtyPath = repoURL.appendingPathComponent("Sources/PreDirty.swift").path
        let createdPath = repoURL.appendingPathComponent("Sources/CreatedByScript.swift").path
        let toDeletePath = repoURL.appendingPathComponent("Sources/Legacy.swift").path

        try FileManager.default.createDirectory(
            at: repoURL.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try "struct Existing {\n    let version = 1\n}\n".write(toFile: trackedPath, atomically: true, encoding: .utf8)
        try "struct PreDirty {\n    let initial = true\n}\n".write(toFile: preDirtyPath, atomically: true, encoding: .utf8)
        try "struct Legacy {}\n".write(toFile: toDeletePath, atomically: true, encoding: .utf8)
        try runShell("git add . && git commit -m 'seed'", cwd: repoURL.path)

        // Dirty `PreDirty.swift` and create an untracked file BEFORE the tracker/turn starts.
        try "struct PreDirty {\n    let initial = false\n}\n".write(toFile: preDirtyPath, atomically: true, encoding: .utf8)
        try "untracked scratch\n".write(
            toFile: repoURL.appendingPathComponent("Sources/UntrackedBeforeTurn.txt").path,
            atomically: true,
            encoding: .utf8
        )

        let canonicalRoot = repoURL.resolvingSymlinksInPath().standardizedFileURL.path
        let tracker = WorkspaceChangeTracker(preferredRootPath: repoURL.path, canonicalRootPath: canonicalRoot)
        let streamId = UUID()
        await tracker.streamDidStart(streamId: streamId, sessionKey: "session-1", cwd: repoURL.path)

        // 1. Python script creates a new file and modifies Existing.swift (zero stdout).
        let pyCmd = """
        python3 -c "
        from pathlib import Path
        Path('Sources/CreatedByScript.swift').write_text('struct CreatedByScript {}\\n')
        p = Path('Sources/Existing.swift')
        p.write_text(p.read_text().replace('version = 1', 'version = 2'))
        "
        """
        await tracker.upsertShellSpan(
            streamId: streamId,
            sessionKey: "session-1",
            toolUseId: "bash-1",
            command: pyCmd,
            cwd: repoURL.path
        )
        try runShell(pyCmd, cwd: repoURL.path)
        let firstEdits = await tracker.endShellSpan(
            streamId: streamId,
            sessionKey: "session-1",
            toolUseId: "bash-1",
            fallbackCommand: pyCmd,
            cwd: repoURL.path
        )

        let firstPaths = Set(firstEdits.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        #expect(firstPaths == ["CreatedByScript.swift", "Existing.swift"])
        #expect(!firstPaths.contains("PreDirty.swift"))
        #expect(!firstPaths.contains("UntrackedBeforeTurn.txt"))

        let createdEdit = try #require(firstEdits.first { $0.path.hasSuffix("CreatedByScript.swift") })
        #expect(createdEdit.kind == .created)
        #expect(createdEdit.beforeContent == nil)
        #expect(createdEdit.chatChange.addedLines == 1)

        let modifiedEdit = try #require(firstEdits.first { $0.path.hasSuffix("Existing.swift") })
        #expect(modifiedEdit.kind == .modified)
        #expect(modifiedEdit.chatChange.addedLines == 1)
        #expect(modifiedEdit.chatChange.removedLines == 1)
        #expect(modifiedEdit.chatChange.diff.contains("+    let version = 2"))

        // 2. Shell `rm` deletes `Legacy.swift`.
        let rmCmd = "rm Sources/Legacy.swift"
        await tracker.upsertShellSpan(
            streamId: streamId,
            sessionKey: "session-1",
            toolUseId: "bash-2",
            command: rmCmd,
            cwd: repoURL.path
        )
        try runShell(rmCmd, cwd: repoURL.path)
        let secondEdits = await tracker.endShellSpan(
            streamId: streamId,
            sessionKey: "session-1",
            toolUseId: "bash-2",
            fallbackCommand: rmCmd,
            cwd: repoURL.path
        )

        #expect(secondEdits.count == 1)
        #expect(secondEdits.first?.kind == .deleted)
        #expect(secondEdits.first?.path.hasSuffix("Legacy.swift") == true)
        #expect(secondEdits.first?.afterContent == nil)
        _ = createdPath

        await tracker.streamDidEnd(streamId: streamId)
    }

    @Test("Concurrent threads running overlapping scripts in the same repo receive only their own file deltas")
    func concurrentOverlappingThreadsIsolatedWithoutBlocking() async throws {
        let repoURL = try makeTemporaryGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try FileManager.default.createDirectory(
            at: repoURL.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        let alphaPath = repoURL.appendingPathComponent("Sources/AlphaService.swift").path
        let betaPath = repoURL.appendingPathComponent("Sources/BetaService.swift").path
        try "struct AlphaService {\n    let count = 0\n}\n".write(toFile: alphaPath, atomically: true, encoding: .utf8)
        try "struct BetaService {\n    let count = 0\n}\n".write(toFile: betaPath, atomically: true, encoding: .utf8)
        try runShell("git add . && git commit -m 'init concurrent'", cwd: repoURL.path)

        let canonicalRoot = repoURL.resolvingSymlinksInPath().standardizedFileURL.path
        let tracker = WorkspaceChangeTracker(preferredRootPath: repoURL.path, canonicalRootPath: canonicalRoot)

        let streamA = UUID()
        let streamB = UUID()
        await tracker.streamDidStart(streamId: streamA, sessionKey: "thread-A", cwd: repoURL.path)
        await tracker.streamDidStart(streamId: streamB, sessionKey: "thread-B", cwd: repoURL.path)

        let cmdA = "python3 -c \"from pathlib import Path; Path('Sources/AlphaService.swift').write_text('struct AlphaService {\\n    let count = 42\\n}\\n')\""
        let cmdB = "python3 -c \"from pathlib import Path; Path('Sources/BetaService.swift').write_text('struct BetaService {\\n    let count = 99\\n}\\n')\""

        // Both spans are active concurrently in the same workspace!
        await tracker.upsertShellSpan(streamId: streamA, sessionKey: "thread-A", toolUseId: "call-A", command: cmdA, cwd: repoURL.path)
        await tracker.upsertShellSpan(streamId: streamB, sessionKey: "thread-B", toolUseId: "call-B", command: cmdB, cwd: repoURL.path)

        // Both scripts mutate their files before EITHER span completes!
        try runShell(cmdA, cwd: repoURL.path)
        try runShell(cmdB, cwd: repoURL.path)

        // Thread B finishes FIRST while Thread A is still active -> Thread B must ONLY get BetaService.swift,
        // and must NOT steal or advance the ledger for AlphaService.swift!
        let editsB = await tracker.endShellSpan(
            streamId: streamB,
            sessionKey: "thread-B",
            toolUseId: "call-B",
            fallbackCommand: cmdB,
            cwd: repoURL.path
        )
        #expect(editsB.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["BetaService.swift"])
        #expect(editsB.first?.chatChange.isAmbiguous == false)

        // Thread A finishes SECOND -> Thread A still receives its full AlphaService.swift delta!
        let editsA = await tracker.endShellSpan(
            streamId: streamA,
            sessionKey: "thread-A",
            toolUseId: "call-A",
            fallbackCommand: cmdA,
            cwd: repoURL.path
        )
        #expect(editsA.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["AlphaService.swift"])
        #expect(editsA.first?.chatChange.isAmbiguous == false)
        #expect(editsA.first?.chatChange.diff.contains("+    let count = 42") == true)

        await tracker.streamDidEnd(streamId: streamA)
        await tracker.streamDidEnd(streamId: streamB)
    }

    @Test("Structured Edit updates ledger so subsequent Bash only records incremental delta")
    func structuredEditAdvancesLedgerBeforeSubsequentBash() async throws {
        let repoURL = try makeTemporaryGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let filePath = repoURL.appendingPathComponent("Config.swift").path
        try "let a = 1\nlet b = 2\n".write(toFile: filePath, atomically: true, encoding: .utf8)
        try runShell("git add . && git commit -m 'init config'", cwd: repoURL.path)

        let canonicalRoot = repoURL.resolvingSymlinksInPath().standardizedFileURL.path
        let tracker = WorkspaceChangeTracker(preferredRootPath: repoURL.path, canonicalRootPath: canonicalRoot)
        let streamId = UUID()
        await tracker.streamDidStart(streamId: streamId, sessionKey: "thread-1", cwd: repoURL.path)

        // Simulate structured `Edit` changing `a = 1` -> `a = 10`.
        let afterStructured = "let a = 10\nlet b = 2\n"
        try afterStructured.write(toFile: filePath, atomically: true, encoding: .utf8)
        await tracker.recordStructuredEdit(path: filePath, modifiedContent: afterStructured)

        // Subsequent `Bash` changes `b = 2` -> `b = 20`.
        let bashCmd = "python3 -c \"from pathlib import Path; Path('Config.swift').write_text('let a = 10\\nlet b = 20\\n')\""
        await tracker.upsertShellSpan(streamId: streamId, sessionKey: "thread-1", toolUseId: "bash-inc", command: bashCmd, cwd: repoURL.path)
        try runShell(bashCmd, cwd: repoURL.path)
        let bashEdits = await tracker.endShellSpan(streamId: streamId, sessionKey: "thread-1", toolUseId: "bash-inc", fallbackCommand: bashCmd, cwd: repoURL.path)

        let edit = try #require(bashEdits.first)
        #expect(edit.beforeContent == afterStructured)
        #expect(edit.chatChange.addedLines == 1)
        #expect(edit.chatChange.removedLines == 1)
        #expect(edit.chatChange.diff.contains("+let b = 20"))
        #expect(!edit.chatChange.diff.contains("-let a = 1"))

        await tracker.streamDidEnd(streamId: streamId)
    }

    // MARK: - Helpers

    private func makeTemporaryGitRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-wct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runShell("git init -q && git config user.email 'test@rxcode.local' && git config user.name 'RxCode Test'", cwd: dir.path)
        return dir
    }

    private func runShell(_ command: String, cwd: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "WorkspaceChangeTrackerTests", code: Int(proc.terminationStatus))
        }
    }
    #endif
}
