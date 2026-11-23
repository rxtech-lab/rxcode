#if os(macOS)
import Foundation
import Testing
import RxCodeCore

struct GitIgnoreFileTests {
    @Test func literalRulesMatchOnlySelectedPaths() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await GitHelper.runWithError(["init", "-q"], at: root.path) == nil)
        #expect(await GitHelper.runWithError(["config", "core.excludesFile", "/dev/null"], at: root.path) == nil)
        for folder in ["generated[1]", "generated1", "nested"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        for path in ["notes [draft]*?.txt ", "notes d1.txt ", "nested/notes [draft]*?.txt ", "generated[1]/output",
                     "generated[1]/tracked", "generated1/output", "already.log"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        #expect(await GitHelper.stage(paths: ["generated[1]/tracked"], at: root.path) == nil)
        let ignore = root.appendingPathComponent(".gitignore")
        let original = Data([0xEF, 0xBB, 0xBF] + Array("# Existing rules\r\n*.log".utf8))
        try original.write(to: ignore)

        let snapshot = try await GitIgnoreFile.load(at: root.path)
        #expect(try await GitIgnoreFile.ignoredPaths(at: root.path) == ["already.log"])
        let patterns = ["notes [draft]*?.txt ", "generated[1]/"].compactMap(GitIgnoreFile.literalPattern(for:))
        let draft = snapshot.adding(patterns)
        let saved = try await snapshot.save(draft)

        #expect(try Data(contentsOf: ignore).starts(with: original))
        #expect(draft.utf8.suffix(2).elementsEqual([0x0D, 0x0A]))
        #expect(saved.adding(patterns) == draft)
        #expect(Set(try await GitIgnoreFile.ignoredPaths(at: root.path)) == ["already.log", "generated[1]/output", "notes [draft]*?.txt "])
    }

    @Test func saveCreatesMissingFileAndRejectsAStaleSnapshot() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await GitIgnoreFile.load(at: root.path)
        let second = try await GitIgnoreFile.load(at: root.path)
        #expect(first.text.isEmpty)

        _ = try await first.save("/cache/\n")
        await #expect(throws: (any Error).self) { try await second.save("/external/\n") }
        #expect(try await GitIgnoreFile.load(at: root.path).text == "/cache/\n")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-ignore-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
#endif
