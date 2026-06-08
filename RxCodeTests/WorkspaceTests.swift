import XCTest
@testable import RxCode

final class WorkspaceTests: XCTestCase {
    func testRegistryCreatesPersonalWorkspaceByDefault() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-workspaces-\(UUID().uuidString)")
            .appendingPathComponent("workspaces.json")
        let registry = WorkspaceRegistry(url: url)

        let snapshot = registry.load()

        XCTAssertEqual(snapshot.active.id, AppWorkspace.personalID)
        XCTAssertEqual(snapshot.active.name, "Personal")
        XCTAssertEqual(snapshot.all.map(\.id), [AppWorkspace.personalID])
    }

    func testRegistryCreatesAndSwitchesWorkspace() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-workspaces-\(UUID().uuidString)")
            .appendingPathComponent("workspaces.json")
        let registry = WorkspaceRegistry(url: url)

        let created = registry.createWorkspace(name: "Work")
        XCTAssertEqual(created.active.name, "Work")
        XCTAssertEqual(created.all.count, 2)

        let switched = registry.switchWorkspace(id: AppWorkspace.personalID)
        XCTAssertEqual(switched?.active.id, AppWorkspace.personalID)
    }

    func testWorkspaceDefaultsNamespaceNonPersonalKeys() {
        let key = "workspaceTest.\(UUID().uuidString)"
        let workspaceID = UUID().uuidString.lowercased()
        let personal = WorkspaceDefaults(workspaceID: AppWorkspace.personalID)
        let workspace = WorkspaceDefaults(workspaceID: workspaceID)

        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: "workspace.\(workspaceID).\(key)")
        }

        personal.set("personal", for: key)
        workspace.set("work", for: key)

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "personal")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspace.\(workspaceID).\(key)"), "work")
        XCTAssertEqual(personal.string(for: key), "personal")
        XCTAssertEqual(workspace.string(for: key), "work")
    }
}
