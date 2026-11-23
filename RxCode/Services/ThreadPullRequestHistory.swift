import Foundation
import RxCodeCore

/// The same head ref can have several successive PRs. A finished PR can cover
/// threads started before its final event, including work done before it opened.
nonisolated struct ThreadPullRequestHistory: Codable, Equatable, Sendable {
    struct FinishedPR: Codable, Equatable {
        let link: ThreadPullRequest
        let endedAt: Date
    }

    let repositories: Set<String>
    let earliestThread: Date
    private(set) var newestUpdate: Date?
    private var finishedByBranch: [String: [FinishedPR]] = [:]

    init(repositories: Set<String>, earliestThread: Date) {
        self.repositories = repositories
        self.earliestThread = earliestThread
    }

    mutating func record(_ revisions: [ThreadPullRequestRevision]) {
        for revision in revisions {
            guard let updated = revision.updatedAt.date else { continue }
            newestUpdate = max(newestUpdate ?? updated, updated)
            let repository = revision.repositoryFullName.lowercased()
            guard repositories.contains(repository), let branch = revision.headRef,
                  let state = PRState(rawValue: revision.state) else { continue }
            let key = "\(repository)#\(branch)"
            var finished = finishedByBranch[key] ?? []
            let previous = finished.first { $0.link.number == revision.number }
            // A merged PR cannot reopen. Later metadata edits can report it as closed.
            if previous?.link.state == .merged { continue }
            finished.removeAll { $0.link.number == revision.number }
            if state != .open, updated >= earliestThread,
               let link = ThreadPullRequest(repository: repository, number: revision.number, state: state, reportedURL: revision.htmlUrl) {
                // A later edit to a finished PR must not extend its lifetime.
                let end = min(updated, previous?.endedAt ?? updated)
                finished.append(FinishedPR(link: link, endedAt: end))
                finished.sort { $0.endedAt < $1.endedAt }
            }
            finishedByBranch[key] = finished.isEmpty ? nil : finished
        }
    }

    func finishedPullRequest(branchKey: String, threadStarted: Date, current: ThreadPullRequest?) -> ThreadPullRequest? {
        finishedByBranch[branchKey]?.first {
            $0.endedAt >= threadStarted && !(current?.state == .open && current?.number == $0.link.number)
        }?.link
    }
}
