import Foundation
import Observation

/// Keeps a terminal process mounted on the same tab when its pane changes.
struct InspectorTerminal: Identifiable {
    let id: UUID
    let process = TerminalProcess()
    let resetID = UUID()
    var customTitle: String?
    /// Stable default-name number, so reordering never renames tabs.
    let number: Int

    init(id: UUID = UUID(), customTitle: String? = nil, number: Int = 1) {
        self.id = id
        self.customTitle = customTitle
        self.number = number
    }

    var title: String { customTitle ?? String(localized: "Terminal \(number)") }
}

@Observable
final class InspectorTerminalStore {
    private static let maximumRetainedSessions = 12

    struct Key: Hashable {
        let tabID: UUID
        let sessionID: String
    }

    struct Session {
        var terminals: [InspectorTerminal]
        var activeID: UUID
        var nextNumber = 2

        var active: InspectorTerminal? { terminals.first { $0.id == activeID } }

        init() {
            let terminal = InspectorTerminal()
            terminals = [terminal]
            activeID = terminal.id
        }
    }

    private(set) var sessions: [Key: Session] = [:]
    private var accessOrder: [String] = []

    func ensureSession(_ key: Key) {
        if sessions[key] == nil { sessions[key] = Session() }
        accessOrder.removeAll { $0 == key.sessionID }
        accessOrder.append(key.sessionID)
        if accessOrder.count > Self.maximumRetainedSessions {
            let evicted = accessOrder.removeFirst()
            for key in sessions.keys where key.sessionID == evicted { removeSession(key) }
        }
    }

    func addTerminal(in key: Key) {
        ensureSession(key)
        let number = sessions[key]?.nextNumber ?? 1
        sessions[key]?.nextNumber = number + 1
        let terminal = InspectorTerminal(number: number)
        sessions[key]?.terminals.append(terminal)
        sessions[key]?.activeID = terminal.id
    }

    func selectTerminal(_ id: UUID, in key: Key) {
        sessions[key]?.activeID = id
    }

    func moveTerminal(_ id: UUID, to target: UUID?, in key: Key) {
        sessions[key]?.terminals.moveTab(id, to: target)
    }

    func closeTerminal(_ id: UUID, in key: Key) {
        guard var session = sessions[key], let index = session.terminals.firstIndex(where: { $0.id == id }) else { return }
        session.terminals.remove(at: index).process.terminate()
        if session.terminals.isEmpty {
            session = Session()
        } else if session.activeID == id {
            session.activeID = session.terminals[max(0, index - 1)].id
        }
        sessions[key] = session
    }

    func renameTerminal(_ id: UUID, title: String, in key: Key) {
        guard let index = sessions[key]?.terminals.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[key]?.terminals[index].customTitle = trimmed.isEmpty ? nil : trimmed
    }

    func resetTerminal(in key: Key) {
        guard let session = sessions[key], let index = session.terminals.firstIndex(where: { $0.id == session.activeID }) else { return }
        let terminal = session.terminals[index]
        terminal.process.terminate()
        sessions[key]?.terminals[index] = InspectorTerminal(id: terminal.id, customTitle: terminal.customTitle, number: terminal.number)
    }

    func clearTerminal(in key: Key) {
        sessions[key]?.active?.process.clear()
    }

    func retainTabs(_ ids: Set<UUID>) {
        for key in sessions.keys where !ids.contains(key.tabID) { removeSession(key) }
        let retained = Set(sessions.keys.map(\.sessionID))
        accessOrder.removeAll { !retained.contains($0) }
    }

    private func removeSession(_ key: Key) {
        sessions.removeValue(forKey: key)?.terminals.forEach { $0.process.terminate() }
    }
}
