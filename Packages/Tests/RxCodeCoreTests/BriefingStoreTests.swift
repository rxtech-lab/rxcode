import Foundation
import Testing
@testable import RxCodeCore

@Suite("Briefing store")
struct BriefingStoreTests {
    private func makeStore() -> BriefingStore {
        BriefingStore(baseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("BriefingStoreTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("Creating a briefing writes its own folder with manifest, content, and asset folders")
    func createWritesFolder() async throws {
        let store = makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let briefing = try await store.create(title: "Weekly", content: "# Hello", createdAt: createdAt)

        let folder = store.folderURL(for: briefing.id)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("briefing.json").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("content.md").path))
        for kind in BriefingAssetKind.allCases {
            #expect(fm.fileExists(atPath: folder.appendingPathComponent(kind.directoryName).path))
        }

        let loaded = try await store.load(briefing.id)
        #expect(loaded.kind == .document)
        #expect(loaded.title == "Weekly")
        #expect(loaded.createdAt == createdAt)
        #expect(try await store.content(of: briefing.id) == "# Hello")
    }

    @Test("HTML content is stored as content.html and switching format replaces the file")
    func htmlFormat() async throws {
        let store = makeStore()
        let briefing = try await store.create(title: "Report", content: "<h1>Hi</h1>", format: .html)
        let folder = store.folderURL(for: briefing.id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("content.html").path))

        let updated = try await store.updateContent(of: briefing.id, content: "# Hi", format: .markdown)
        #expect(updated.format == .markdown)
        #expect(updated.createdAt == briefing.createdAt)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("content.html").path))
        #expect(try await store.content(of: briefing.id) == "# Hi")
    }

    @Test("List returns briefings newest first")
    func listSortsByCreation() async throws {
        let store = makeStore()
        try await store.create(title: "Old", content: "", createdAt: Date(timeIntervalSince1970: 100))
        try await store.create(title: "New", content: "", createdAt: Date(timeIntervalSince1970: 200))
        #expect(await store.list().map(\.title) == ["New", "Old"])
    }

    @Test("Assets are sorted into image, video, and file folders")
    func assetsByKind() async throws {
        let store = makeStore()
        let briefing = try await store.create(title: "Media", content: "")
        let image = try await store.addAsset(to: briefing.id, fileName: "chart.png", data: Data([1, 2, 3]))
        let video = try await store.addAsset(to: briefing.id, fileName: "demo.mp4", data: Data([4]))
        let file = try await store.addAsset(to: briefing.id, fileName: "report.pdf", data: Data([5]))

        #expect(image.relativePath == "images/chart.png")
        #expect(image.byteCount == 3)
        #expect(video.kind == .video)
        #expect(file.kind == .file)
        #expect(try await store.assets(of: briefing.id) == [image, video, file])

        try await store.removeAsset(image, from: briefing.id)
        #expect(try await store.assets(of: briefing.id) == [video, file])
    }

    @Test("Duplicate asset names get a suffix unless overwriting")
    func duplicateNames() async throws {
        let store = makeStore()
        let briefing = try await store.create(title: "Dupes", content: "")
        _ = try await store.addAsset(to: briefing.id, fileName: "a.png", data: Data([1]))
        let second = try await store.addAsset(to: briefing.id, fileName: "a.png", data: Data([2]))
        #expect(second.fileName == "a 2.png")
        let replaced = try await store.addAsset(to: briefing.id, fileName: "a.png", data: Data([3, 3]), overwrite: true)
        #expect(replaced.fileName == "a.png")
        #expect(try await store.assets(of: briefing.id).count == 2)
    }

    @Test("Asset names cannot escape the briefing folder")
    func rejectsPathTraversal() async throws {
        let store = makeStore()
        let briefing = try await store.create(title: "Safe", content: "")
        for name in ["../evil.png", "a/b.png", "..", ".hidden", "  "] {
            await #expect(throws: BriefingStoreError.self) {
                try await store.addAsset(to: briefing.id, fileName: name, data: Data())
            }
        }
    }

    @Test("Deleting a briefing removes its folder")
    func deleteRemovesFolder() async throws {
        let store = makeStore()
        let briefing = try await store.create(title: "Gone", content: "x")
        try await store.delete(briefing.id)
        #expect(!FileManager.default.fileExists(atPath: store.folderURL(for: briefing.id).path))
        #expect(await store.list().isEmpty)
    }

    @Test("Manifests missing optional fields still decode")
    func tolerantDecoding() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"Legacy"}"#
        let decoded = try JSONDecoder().decode(BriefingDocument.self, from: Data(json.utf8))
        #expect(decoded.kind == .document)
        #expect(decoded.format == .markdown)
        #expect(decoded.projectId == nil)
    }
}
