import Foundation
import RxCodeCore
import os

struct AppWorkspace: Codable, Identifiable, Hashable, Sendable {
    nonisolated static let personalID = AppSupport.personalWorkspaceID

    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date

    nonisolated static var personal: AppWorkspace {
        AppWorkspace(id: personalID, name: "Personal", createdAt: .distantPast, updatedAt: .distantPast)
    }

    nonisolated var isPersonal: Bool { id == Self.personalID }
    nonisolated var storageURL: URL { AppSupport.workspaceScopedURL(id: id) }
    nonisolated var rxAuthKeychainService: String {
        isPersonal ? RxAuthService.defaultKeychainService : "\(RxAuthService.defaultKeychainService).workspace.\(id)"
    }
    nonisolated var openAISummarizationKeychainAccount: String {
        isPersonal ? AppState.openAISummarizationKeychainAccount : "\(AppState.openAISummarizationKeychainAccount).\(id)"
    }
}

final class WorkspaceRegistry {
    private struct Snapshot: Codable {
        var activeWorkspaceID: String
        var workspaces: [AppWorkspace]
    }

    private let url: URL
    private let logger = Logger(subsystem: "com.claudework", category: "WorkspaceRegistry")

    init(url: URL = AppSupport.bundleScopedURL.appendingPathComponent("workspaces.json")) {
        self.url = url
    }

    func load() -> (active: AppWorkspace, all: [AppWorkspace]) {
        var snapshot = readSnapshot() ?? Snapshot(activeWorkspaceID: AppWorkspace.personalID, workspaces: [.personal])
        normalize(&snapshot)
        persist(snapshot)
        let active = snapshot.workspaces.first { $0.id == snapshot.activeWorkspaceID } ?? snapshot.workspaces[0]
        return (active, snapshot.workspaces)
    }

    func createWorkspace(name: String) -> (active: AppWorkspace, all: [AppWorkspace]) {
        var snapshot = readSnapshot() ?? Snapshot(activeWorkspaceID: AppWorkspace.personalID, workspaces: [.personal])
        normalize(&snapshot)
        let now = Date()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Workspace" : trimmed
        let workspace = AppWorkspace(id: UUID().uuidString.lowercased(), name: uniqueName(baseName, in: snapshot.workspaces), createdAt: now, updatedAt: now)
        snapshot.workspaces.append(workspace)
        snapshot.activeWorkspaceID = workspace.id
        persist(snapshot)
        return (workspace, snapshot.workspaces)
    }

    func switchWorkspace(id: String) -> (active: AppWorkspace, all: [AppWorkspace])? {
        var snapshot = readSnapshot() ?? Snapshot(activeWorkspaceID: AppWorkspace.personalID, workspaces: [.personal])
        normalize(&snapshot)
        guard let active = snapshot.workspaces.first(where: { $0.id == id }) else { return nil }
        snapshot.activeWorkspaceID = active.id
        persist(snapshot)
        return (active, snapshot.workspaces)
    }

    func renameWorkspace(id: String, name: String) -> (active: AppWorkspace, all: [AppWorkspace])? {
        guard id != AppWorkspace.personalID else { return nil }
        var snapshot = readSnapshot() ?? Snapshot(activeWorkspaceID: AppWorkspace.personalID, workspaces: [.personal])
        normalize(&snapshot)
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var others = snapshot.workspaces
        others.remove(at: index)
        snapshot.workspaces[index].name = uniqueName(trimmed, in: others)
        snapshot.workspaces[index].updatedAt = Date()
        persist(snapshot)
        let active = snapshot.workspaces.first { $0.id == snapshot.activeWorkspaceID } ?? snapshot.workspaces[0]
        return (active, snapshot.workspaces)
    }

    func deleteWorkspace(id: String) -> (active: AppWorkspace, all: [AppWorkspace])? {
        guard id != AppWorkspace.personalID else { return nil }
        var snapshot = readSnapshot() ?? Snapshot(activeWorkspaceID: AppWorkspace.personalID, workspaces: [.personal])
        normalize(&snapshot)
        guard snapshot.workspaces.contains(where: { $0.id == id }) else { return nil }
        snapshot.workspaces.removeAll { $0.id == id }
        if snapshot.activeWorkspaceID == id {
            snapshot.activeWorkspaceID = AppWorkspace.personalID
        }
        persist(snapshot)
        let active = snapshot.workspaces.first { $0.id == snapshot.activeWorkspaceID } ?? snapshot.workspaces[0]
        return (active, snapshot.workspaces)
    }

    private func normalize(_ snapshot: inout Snapshot) {
        if !snapshot.workspaces.contains(where: { $0.id == AppWorkspace.personalID }) {
            snapshot.workspaces.insert(.personal, at: 0)
        }
        if !snapshot.workspaces.contains(where: { $0.id == snapshot.activeWorkspaceID }) {
            snapshot.activeWorkspaceID = AppWorkspace.personalID
        }
        snapshot.workspaces.sort {
            if $0.id == AppWorkspace.personalID { return true }
            if $1.id == AppWorkspace.personalID { return false }
            return $0.createdAt < $1.createdAt
        }
    }

    private func readSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Snapshot.self, from: data)
        } catch {
            logger.error("Failed to decode workspaces: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func persist(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uniqueName(_ name: String, in workspaces: [AppWorkspace]) -> String {
        let existing = Set(workspaces.map { $0.name.lowercased() })
        guard existing.contains(name.lowercased()) else { return name }
        var index = 2
        while existing.contains("\(name) \(index)".lowercased()) {
            index += 1
        }
        return "\(name) \(index)"
    }
}

struct WorkspaceDefaults: Sendable {
    let workspaceID: String
    nonisolated var isPersonal: Bool { workspaceID == AppSupport.personalWorkspaceID }

    nonisolated func key(_ raw: String) -> String {
        isPersonal ? raw : "workspace.\(workspaceID).\(raw)"
    }

    nonisolated func string(for raw: String) -> String? {
        UserDefaults.standard.string(forKey: key(raw))
    }

    nonisolated func set(_ value: String?, for raw: String) {
        let key = key(raw)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    nonisolated func bool(for raw: String, default defaultValue: Bool) -> Bool {
        let key = key(raw)
        if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    nonisolated func set(_ value: Bool, for raw: String) {
        UserDefaults.standard.set(value, forKey: key(raw))
    }

    nonisolated func int(for raw: String, default defaultValue: Int) -> Int {
        let key = key(raw)
        guard let value = UserDefaults.standard.object(forKey: key) as? Int else { return defaultValue }
        return value
    }

    nonisolated func set(_ value: Int, for raw: String) {
        UserDefaults.standard.set(value, forKey: key(raw))
    }

    nonisolated func data(for raw: String) -> Data? {
        UserDefaults.standard.data(forKey: key(raw))
    }

    nonisolated func set(_ value: Data?, for raw: String) {
        let key = key(raw)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    nonisolated func stringArray(for raw: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(raw)) ?? []
    }

    nonisolated func set(_ value: [String], for raw: String) {
        UserDefaults.standard.set(value, forKey: key(raw))
    }
}
