import Foundation
import RxCodeSync

/// Derived once when session summaries change, rather than for every visible row
/// on every streaming message or unrelated app-state publication.
struct MobileSessionListIndex {
    struct ProjectRows {
        var threadCount = 0
        var activeJobCount = 0
        var lastActivity: Date?
        var sessions: [SessionSummary] = []
        var roots: [SessionSummary] = []
        var children: [String: [SessionSummary]] = [:]
    }

    var projects: [UUID: ProjectRows] = [:]

    init(sessions: [SessionSummary] = []) {
        for session in sessions {
            if !session.isArchived {
                projects[session.projectId, default: ProjectRows()].threadCount += 1
                projects[session.projectId, default: ProjectRows()].sessions.append(session)
            }
            if session.isStreaming {
                projects[session.projectId, default: ProjectRows()].activeJobCount += 1
            }
            let previous = projects[session.projectId]?.lastActivity ?? session.updatedAt
            projects[session.projectId, default: ProjectRows()].lastActivity = max(previous, session.updatedAt)
        }
        for id in Array(projects.keys) {
            guard var rows = projects[id] else { continue }
            rows.sessions.sort {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
            let ids = Set(rows.sessions.map(\.id))
            for session in rows.sessions {
                if let parent = session.parentThreadId, parent != session.id, ids.contains(parent) {
                    rows.children[parent, default: []].append(session)
                } else {
                    rows.roots.append(session)
                }
            }
            rows.children = rows.children.mapValues {
                $0.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                    return $0.id < $1.id
                }
            }
            projects[id] = rows
        }
    }
}
