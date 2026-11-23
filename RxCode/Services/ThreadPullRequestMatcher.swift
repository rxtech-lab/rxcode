import CryptoKit
import Foundation
import RxCodeChatKit
import RxCodeCore
import SwiftData

nonisolated struct ThreadPullRequestRevision: Decodable, Sendable {
    let repositoryFullName: String
    let number: Int
    let state: String
    let htmlUrl: String?
    let baseSha: String?
    let headSha: String?
    let updatedAt: FlexibleTimestamp
    var headRef: String?
}

/// Finds PRs that contain a thread's edits when its recorded checkout has no PR.
/// Git and the saved file snapshots provide the evidence without reading chat text.
actor ThreadPullRequestMatcher {
    private struct RevisionRange: Hashable {
        let root: String
        let base: String
        let head: String
    }

    private struct BlobChange: Equatable, Sendable {
        let before: String?
        let after: String?
    }

    private struct PullRequestChange: Sendable {
        let link: ThreadPullRequest
        let updatedAt: Date
        let blobs: BlobChange
    }

    private var changesByRevision: [RevisionRange: [String: BlobChange]] = [:]

    func match(
        _ revisions: [ThreadPullRequestRevision],
        to threads: [ChatSession.Summary],
        in projects: [Project],
        reader: ThreadStoreReader
    ) async -> [String: ThreadPullRequest] {
        let threadsByProject = Dictionary(grouping: threads, by: \.projectId)
        let revisionsByRepo = Dictionary(grouping: revisions) { $0.repositoryFullName.lowercased() }
        var matches: [String: ThreadPullRequest] = [:]
        var usedRanges: Set<RevisionRange> = []

        for project in projects {
            guard !Task.isCancelled,
                  let threads = threadsByProject[project.id],
                  let earliestThread = threads.map(\.createdAt).min(),
                  let repository = project.gitHubRepo,
                  let revisions = revisionsByRepo[repository.lowercased()],
                  let rootOutput = await GitHelper.run(["rev-parse", "--show-toplevel"], at: project.path) else { continue }
            let rootPath = rootOutput.trimmingCharacters(in: .newlines)
            guard !rootPath.isEmpty else { continue }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path

            var changesByPath: [String: [PullRequestChange]] = [:]
            for revision in revisions {
                guard let updatedAt = revision.updatedAt.date, updatedAt >= earliestThread,
                      let base = revision.baseSha, Self.isGitSHA(base),
                      let head = revision.headSha, Self.isGitSHA(head),
                      let state = PRState(rawValue: revision.state),
                      let link = ThreadPullRequest(
                        repository: repository,
                        number: revision.number,
                        state: state,
                        reportedURL: revision.htmlUrl
                      ) else { continue }

                let range = RevisionRange(root: root, base: base, head: head)
                usedRanges.insert(range)
                for (path, blobs) in await committedChanges(in: range) {
                    changesByPath[path, default: []].append(PullRequestChange(
                        link: link, updatedAt: updatedAt, blobs: blobs
                    ))
                }
            }
            guard !changesByPath.isEmpty else { continue }
            let roots = threads.reduce(into: [String: String]()) { roots, thread in
                roots[thread.id] = thread.worktreePath.map {
                    URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
                } ?? root
            }
            let projectMatches = await Self.matchEdits(in: reader, roots: roots, changesByPath: changesByPath)
            matches.merge(projectMatches) { current, _ in current }
        }
        changesByRevision = changesByRevision.filter { usedRanges.contains($0.key) }
        return matches
    }

    private func committedChanges(in range: RevisionRange) async -> [String: BlobChange] {
        if let cached = changesByRevision[range] { return cached }
        guard let raw = await GitHelper.run([
            "diff", "--raw", "-z", "--no-abbrev", "--no-renames", "--no-ext-diff",
            "--no-textconv", "--ignore-submodules", "\(range.base)...\(range.head)", "--"
        ], at: range.root) else { return [:] }

        let fields = raw.split(separator: "\0")
        var changes: [String: BlobChange] = [:]
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            let header = fields[index].split(separator: " ")
            guard header.count == 5,
                  header[0].hasPrefix(":100") || header[0] == ":000000",
                  header[1].hasPrefix("100") || header[1] == "000000",
                  header[2] != header[3] else { continue }
            let before = header[0] == ":000000" ? nil : String(header[2])
            let after = header[1] == "000000" ? nil : String(header[3])
            changes[String(fields[index + 1])] = BlobChange(before: before, after: after)
        }
        changesByRevision[range] = changes
        return changes
    }

    private static func matchEdits(
        in reader: ThreadStoreReader,
        roots: [String: String],
        changesByPath: [String: [PullRequestChange]]
    ) async -> [String: ThreadPullRequest] {
        await reader.read { context in
            var matches: [String: [Int: ThreadPullRequest]] = [:]
            let ids = Array(roots.keys)
            for start in stride(from: 0, to: ids.count, by: 250) {
                let batch = Array(ids[start..<min(start + 250, ids.count)])
                var descriptor = FetchDescriptor<ThreadFileEdit>(predicate: #Predicate { batch.contains($0.sessionId) })
                descriptor.propertiesToFetch = [
                    \.sessionId, \.path, \.updatedAt, \.isAmbiguous, \.hasExternalInterleaving, \.isDeleted
                ]
                for edit in (try? context.fetch(descriptor)) ?? [] {
                    guard edit.isAmbiguous != true, edit.hasExternalInterleaving != true,
                          !PlanLogic.isPlanFilePath(edit.path), let root = roots[edit.sessionId],
                          let path = relativePath(edit.path, in: root),
                          let changes = changesByPath[path]?.filter({ edit.updatedAt <= $0.updatedAt }),
                          !changes.isEmpty else { continue }
                    let deleted = edit.isDeleted == true
                    guard deleted ? edit.originalContent != nil : edit.modifiedContent != nil else { continue }
                    let blobs = BlobChange(
                        before: edit.originalContent.map(gitBlobSHA),
                        after: deleted ? nil : edit.modifiedContent.map(gitBlobSHA)
                    )
                    for change in changes where change.blobs == blobs {
                        guard let number = change.link.number else { continue }
                        matches[edit.sessionId, default: [:]][number] = change.link
                    }
                }
            }
            return matches.compactMapValues { $0.count == 1 ? $0.values.first : nil }
        }
    }

    private static func relativePath(_ path: String, in root: String) -> String? {
        let base = URL(fileURLWithPath: root, isDirectory: true)
        let file = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let absolute = file.path.hasPrefix(prefix)
            ? file.path
            : file.resolvingSymlinksInPath().standardizedFileURL.path
        guard absolute.hasPrefix(prefix) else { return nil }
        return String(absolute.dropFirst(prefix.count))
    }

    private static func isGitSHA(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func gitBlobSHA(_ content: String) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(content.utf8.count)\0".utf8))
        hash.update(data: Data(content.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
