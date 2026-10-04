import Foundation
import Testing
@testable import RxCodeCore

@Suite("Briefing drafts, publishing, and agent tools")
struct BriefingPublishTests {
    private func makeStore() -> BriefingStore {
        BriefingStore(baseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("BriefingPublishTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("Drafts stay unpublished until publish stamps publishedAt")
    func publishDraft() async throws {
        let store = makeStore()
        let draft = try await store.create(title: "Draft", content: "", isDraft: true)
        #expect(draft.isDraft)
        #expect(draft.publishedAt == nil)
        #expect(try await store.load(draft.id).isDraft)

        let publishDate = Date(timeIntervalSince1970: 1_900_000_000)
        let published = try await store.publish(draft.id, at: publishDate)
        #expect(published.isPublished)
        #expect(published.publishedAt == publishDate)
        #expect(try await store.load(draft.id) == published)

        let unpublished = try await store.unpublish(draft.id)
        #expect(unpublished.isDraft)
        #expect(unpublished.publishedAt == nil)
    }

    @Test("Briefings created without a draft flag are published at creation")
    func defaultIsPublished() async throws {
        let store = makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let briefing = try await store.create(title: "Now", content: "", createdAt: createdAt)
        #expect(briefing.isPublished)
        #expect(briefing.publishedAt == createdAt)
    }

    @Test("Manifests without draft fields decode as published")
    func legacyManifestDecodes() throws {
        let json = #"{"id":"7C8A1F2E-3B4D-4E5F-8A9B-0C1D2E3F4A5B","title":"Old","createdAt":"2027-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let briefing = try decoder.decode(BriefingDocument.self, from: Data(json.utf8))
        #expect(briefing.isPublished)
        #expect(briefing.publishedAt == briefing.createdAt)
    }

    @Test("Asset relative paths parse only for asset folders")
    func assetRelativePath() {
        let asset = BriefingAsset(relativePath: "images/chart.png")
        #expect(asset?.kind == .image)
        #expect(asset?.fileName == "chart.png")
        #expect(BriefingAsset(relativePath: "videos/demo.mp4")?.kind == .video)
        #expect(BriefingAsset(relativePath: "briefing.json") == nil)
        #expect(BriefingAsset(relativePath: "other/x.png") == nil)
        #expect(BriefingAsset(relativePath: "images/nested/x.png") == nil)
        #expect(BriefingAsset(relativePath: "images/") == nil)
    }

    @Test("Briefing tools are registered for every backend")
    func briefingToolsRegistered() {
        let names = Set(IDEToolRegistry.tools(for: []).map(\.name))
        for name in [
            "ide__briefing_list", "ide__briefing_get", "ide__briefing_create", "ide__briefing_update",
            "ide__briefing_delete", "ide__briefing_add_file", "ide__briefing_delete_file", "ide__briefing_publish",
            "ide__send_notification",
        ] {
            #expect(names.contains(name))
        }
    }
}
