#if os(macOS)
import Foundation
import Testing
@testable import RxCodeCore

/// Regression: `GitHelper` used to wait for git to exit before reading its
/// pipes. Output larger than the 64 KB pipe buffer blocked git on write
/// forever, which wedged the workspace change tracker and every agent stream
/// started in that workspace (Codex threads spun with no messages).
@Suite("GitHelper large-output pipes", .timeLimit(.minutes(1)))
struct GitHelperPipeDeadlockTests {
    private func makeRepo(untrackedFiles: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["init", "-q"]
        gitInit.currentDirectoryURL = root
        try gitInit.run()
        gitInit.waitUntilExit()

        let dir = root.appendingPathComponent("generated-output-directory-with-a-long-name", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<untrackedFiles {
            let file = dir.appendingPathComponent("untracked-file-with-a-fairly-long-name-\(index).txt")
            try Data("x\n".utf8).write(to: file)
        }
        return root
    }

    @Test("run() returns porcelain output larger than the pipe buffer")
    func runDrainsLargeStdout() async throws {
        let repo = try makeRepo(untrackedFiles: 2_000)
        defer { try? FileManager.default.removeItem(at: repo) }

        let output = try #require(await GitHelper.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            at: repo.path
        ))
        #expect(output.utf8.count > 65_536)
        #expect(output.split(separator: "\0").count >= 2_000)
    }

    @Test("execute() feeds large stdin while draining large stdout")
    func executeStreamsStdinAndStdout() async throws {
        let repo = try makeRepo(untrackedFiles: 0)
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("ignored/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))

        let paths = (0..<3_000).map { "ignored/some-generated-artifact-with-a-long-name-\($0).o" }
        let payload = Data((paths.joined(separator: "\0") + "\0").utf8)
        let output = try #require(await GitHelper.execute(
            ["check-ignore", "-z", "--stdin"],
            at: repo.path,
            input: payload
        ))
        #expect(output.status == 0)
        #expect(output.stdout.count > 65_536)
        #expect(output.stdout.split(separator: 0).count == paths.count)
    }
}
#endif
