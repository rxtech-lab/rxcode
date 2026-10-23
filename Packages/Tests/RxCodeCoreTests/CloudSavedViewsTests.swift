import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cloud saved views")
struct CloudSavedViewsTests {
    private func wire(_ name: String, id: UUID = UUID()) -> CloudSavedView {
        CloudSavedView(view: TaskSavedView(id: id, name: name), sync: CloudBoardSyncState())
    }

    @Test func migrationAndRemoteOnlyViews() {
        let desktop = wire("v1.20.0")
        let phone = wire("Phone")
        #expect(CloudSavedViews.merging(local: [], base: nil, remote: [desktop]) == [desktop])
        #expect(CloudSavedViews.merging(local: [phone], base: nil, remote: [desktop]) == [phone, desktop])
    }

    @Test func editsDeletionsAndReordering() {
        let a = wire("A"), b = wire("B"), c = wire("C")
        var edited = a
        edited.view.name = "Renamed on phone"
        #expect(CloudSavedViews.merging(local: [a, b], base: [a, b], remote: [edited, b, c]) == [edited, b, c])
        #expect(CloudSavedViews.merging(local: [b], base: [a, b], remote: [a, b, c]) == [b, c])
        #expect(CloudSavedViews.merging(local: [a, b], base: [a, b], remote: [b]) == [b])
        #expect(CloudSavedViews.merging(local: [b, a], base: [a, b], remote: [a, b, c]) == [b, a, c])
    }

    @Test func concurrentDefaultsStayUnique() {
        let a = wire("A"), b = wire("B")
        var local = a, remote = b
        local.view.isDefault = true
        remote.view.isDefault = true
        let merged = CloudSavedViews.merging(local: [local, b], base: [a, b], remote: [a, remote])
        #expect(merged.filter { $0.view.isDefault }.map(\.id) == [a.id])
    }

    @Test func storyFiltersTranslateBetweenDeviceIdentities() throws {
        let macID = UUID(), phoneID = UUID()
        let fields = CloudStoryFields(title: "Story")
        let mac = CloudBoardSyncState(stories: [macID: CloudItemLink(remoteId: "remote-story", base: fields)])
        let phone = CloudBoardSyncState(stories: [phoneID: CloudItemLink(remoteId: "remote-story", base: fields)])
        let view = TaskSavedView(name: "Story", storyIds: [macID])
        let wire = CloudSavedView(view: view, sync: mac)
        let decoded = try JSONDecoder().decode(CloudSavedView.self, from: JSONEncoder().encode(wire))
        #expect(decoded.view.storyIds.isEmpty)
        #expect(decoded.localView(sync: phone).storyIds == [phoneID])
        #expect(!decoded.localView(sync: CloudBoardSyncState()).storyIds.isEmpty)
    }

    @Test func oldSyncStateDecodesWithoutViewBase() throws {
        let sync = try JSONDecoder().decode(CloudBoardSyncState.self, from: Data("{}".utf8))
        #expect(sync.savedViewsBase == nil)
    }
}
