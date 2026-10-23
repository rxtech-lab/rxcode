import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cloud saved views")
struct CloudSavedViewsTests {
    @Test func mobileEditsPreserveLatestRemoteSwiftSource() {
        var remote = wire("Desktop")
        remote.view.filterScript = "new source"
        var draft = remote
        draft.view.name = "Renamed on phone"
        draft.view.filterScript = "stale source"
        let result = CloudSavedViews.preservingRemoteScripts(in: [draft], remote: [remote])
        #expect(result[0].view.name == "Desktop")
        #expect(result[0].view.filterScript == "new source")

        remote.view.filterScript = nil
        #expect(CloudSavedViews.preservingRemoteScripts(in: [draft], remote: [remote])[0].view.filterScript == nil)
        #expect(CloudSavedViews.preservingRemoteScripts(in: [draft], remote: [])[0].view.filterScript == nil)
        draft.view.filterScript = nil
        remote.view.filterScript = "preserved source"
        #expect(CloudSavedViews.preservingRemoteScripts(in: [draft], remote: [remote])[0].view.filterScript == "preserved source")
    }

    @Test func snapshotIDsTranslateAndStandardViewsStayEditable() throws {
        let localID = UUID(), phoneID = UUID()
        let host = CloudBoardSyncState(stories: [localID: CloudItemLink(remoteId: "remote", base: CloudStoryFields(title: "Story"))])
        let phone = CloudBoardSyncState(stories: [phoneID: CloudItemLink(remoteId: "remote", base: CloudStoryFields(title: "Story"))])
        var view = TaskSavedView(name: "Swift", filterScript: "source")
        view.filterSnapshot = TaskFilterSnapshot(source: "source", tasks: [], stories: [localID.uuidString])
        let wire = CloudSavedView(view: view, sync: host)
        #expect(wire.view.filterSnapshot?.stories == ["remote"])
        let decoded = try JSONDecoder().decode(CloudSavedView.self, from: JSONEncoder().encode(wire))
        #expect(decoded.localView(sync: phone).filterSnapshot?.stories == [phoneID.uuidString])
        #expect(decoded.localView(sync: CloudBoardSyncState()).filterSnapshot?.stories == [])
        #expect(CloudSavedViews.preservingRemoteScripts(in: [], remote: [wire]) == [wire])
        var previousDefault = wire
        previousDefault.view.isDefault = true
        #expect(!CloudSavedViews.preservingRemoteScripts(in: [wire], remote: [previousDefault])[0].view.isDefault)
        var standard = wire
        standard.view.filterScript = nil
        var edited = standard
        edited.view.name = "Editable"
        #expect(CloudSavedViews.preservingRemoteScripts(in: [edited], remote: [standard])[0].view.name == "Editable")
    }

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
