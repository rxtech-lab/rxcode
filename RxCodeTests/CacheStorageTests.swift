import Foundation
import RxCodeCore
import SwiftUI
import XCTest
@testable import RxCode

@MainActor
final class CacheStorageTests: XCTestCase {
    private static var retainedStores: [ThreadStore] = []

    func testLaunchRestoresThreadAndBriefingMergeStatusBeforeTheFirstPoll() async throws {
        let workspace = AppWorkspace(id: UUID().uuidString, name: "Launch", createdAt: .now, updatedAt: .now)
        let state = AppState(core: AppCore(), workspace: workspace, startBackgroundServices: false)
        let project = Project(name: "Repo", path: workspace.storageURL.path, gitHubRepo: "Owner/Repo")
        try await state.persistence.saveProjects([project])

        let checkout = ChatSession(id: "checkout", projectId: project.id).summary
        let worktree = ChatSession(id: "worktree", projectId: project.id, worktreeBranch: "Feature").summary
        let review = ChatSession(id: "review", projectId: project.id, parentThreadId: worktree.id).summary
        let inferred = ChatSession(id: "inferred", projectId: project.id).summary
        let mergedAt = Date()
        let afterMerge = mergedAt.addingTimeInterval(1)
        let reused = ChatSession(id: "reused", projectId: project.id, createdAt: afterMerge).summary
        let newWorktree = ChatSession(id: "new-worktree", projectId: project.id, createdAt: afterMerge, worktreeBranch: "Feature").summary
        let newReview = ChatSession(id: "new-review", projectId: project.id, createdAt: afterMerge, parentThreadId: worktree.id).summary
        let newThreads = [reused, newWorktree, newReview]
        for thread in [checkout, worktree, review, inferred] + newThreads { state.threadStore.upsert(thread) }
        state.threadStore.setCheckoutBranch(sessionId: checkout.id, branch: "Feature")
        state.threadStore.setCheckoutBranch(sessionId: reused.id, branch: "Feature")

        func status(_ number: Int, _ state: PRState) -> ProjectCIStatus {
            ProjectCIStatus(
                owner: "owner", repo: "repo", branch: "Feature", found: true, overallState: .failure,
                lastUpdated: nil, headSha: nil, prNumber: number, prState: state.rawValue, prUrl: nil, workflows: [], failing: []
            )
        }
        func merge(_ number: Int, at date: Date) -> ThreadPullRequestRevision {
            ThreadPullRequestRevision(
                repositoryFullName: "Owner/Repo", number: number, state: "merged", htmlUrl: nil,
                baseSha: nil, headSha: nil, updatedAt: FlexibleTimestamp(date: date), headRef: "Feature"
            )
        }
        let match = try XCTUnwrap(ThreadPullRequest(repository: "Owner/Repo", number: 43, state: .merged, reportedURL: nil))
        let key = "owner/repo#Feature"
        let legacy = BranchStatusSnapshot(accountID: "returning-user", byBranch: [key: status(42, .merged)], inferredBySession: [inferred.id: match])
        var cached = legacy
        var history = ThreadPullRequestHistory(repositories: ["owner/repo"], earliestThread: checkout.createdAt)
        history.record([merge(42, at: mergedAt)])
        cached.threadHistory = history
        try await CacheStorageService.shared.saveBranchStatus(cached, workspaceID: workspace.id)
        state.workspaceDefaults.set("another-user", for: AppState.branchStatusAccountKey)
        state.restoreBranchStatus(cached)
        XCTAssertTrue(state.branchStatus.byBranch.isEmpty)

        state.workspaceDefaults.set(cached.accountID, for: AppState.branchStatusAccountKey)
        await state.initialize()
        XCTAssertTrue(state.isInitialized)
        XCTAssertFalse(state.isSignedIn)
        XCTAssertNil(state.ciStatusPollerTask)
        XCTAssertEqual(state.ciStatus(forProjectId: project.id, branch: "Feature")?.pullRequestState, .merged)
        for thread in [checkout, worktree, review] {
            let link = state.pullRequest(forThread: thread, in: project)
            XCTAssertEqual(link?.number, 42)
            XCTAssertEqual(link?.state, .merged)
        }
        XCTAssertEqual(state.pullRequest(forThread: inferred, in: project), match)
        for thread in newThreads { XCTAssertNil(state.pullRequest(forThread: thread, in: project)) }
        XCTAssertNil(state.ciStatus(forProjectId: project.id, branch: "feature"))
        XCTAssertFalse(state.anyCIFailing, "Only a live CI result should drive project failure handling")

        let badge = BriefingPRStatusView(projectId: project.id, branch: "Feature", project: project)
            .environment(state)
            .environment(WindowState())
            .padding(8)
        let renderer = ImageRenderer(content: badge)
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.nsImage))
        attachment.name = "Briefing merge badge before the first poll"
        attachment.lifetime = .keepAlways
        add(attachment)

        // A snapshot written before PR history was cached has only a branch name.
        state.branchStatus = try JSONDecoder().decode(BranchStatusSnapshot.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(state.pullRequest(forThread: reused, in: project))
        XCTAssertEqual(state.pullRequest(forThread: inferred, in: project), match)

        // A subsequent open PR belongs to the new threads. Old rows still link to #42.
        state.branchStatus = cached
        state.branchStatus.byBranch[key] = status(44, .open)
        XCTAssertEqual(state.pullRequest(forThread: checkout, in: project)?.number, 42)
        for thread in newThreads { XCTAssertEqual(state.pullRequest(forThread: thread, in: project)?.number, 44) }

        let secondMerge = afterMerge.addingTimeInterval(60)
        history.record([merge(44, at: secondMerge), merge(42, at: secondMerge)])
        state.branchStatus.threadHistory = history
        state.branchStatus.byBranch[key] = status(44, .merged)
        XCTAssertEqual(state.pullRequest(forThread: checkout, in: project)?.number, 42)
        XCTAssertEqual(state.pullRequest(forThread: reused, in: project)?.number, 44)
        let third = ChatSession(id: "third", projectId: project.id, createdAt: secondMerge.addingTimeInterval(1), worktreeBranch: "Feature").summary
        XCTAssertNil(state.pullRequest(forThread: third, in: project))

        var relinkedProject = project
        relinkedProject.gitHubRepo = "Owner/Other"
        XCTAssertNil(state.pullRequest(forThread: inferred, in: relinkedProject))
        await state.signOutRxAuth()
        XCTAssertNil(state.pullRequest(forThread: checkout, in: project))
        XCTAssertNil(state.workspaceDefaults.string(for: AppState.branchStatusAccountKey))
        let afterSignOut = await CacheStorageService.shared.loadBranchStatus(workspaceID: workspace.id)
        XCTAssertNil(afterSignOut)
    }

    func testClearingCachedRecordsPreservesChats() throws {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        let projectId = UUID()
        store.context.insert(ChatThread(id: "thread-1", projectId: projectId, title: "Keep chat"))
        store.upsertThreadSummary(
            sessionId: "thread-1", projectId: projectId, branch: "main",
            title: "Summary", summary: "Cached summary"
        )
        store.upsertBranchBriefing(projectId: projectId, branch: "main", briefing: "Cached briefing")
        store.context.insert(ThreadEmbeddingChunk(
            id: "thread-1#0", threadId: "thread-1", projectId: projectId,
            chunkIndex: 0, text: "Cached chunk", vector: Data(), dim: 0
        ))
        store.save()

        try store.clearCachedRecords()

        XCTAssertEqual(store.loadAllSummaries().map(\.title), ["Keep chat"])
        XCTAssertTrue(store.allThreadSummaryItems().isEmpty)
        XCTAssertTrue(store.allBranchBriefingItems().isEmpty)
        XCTAssertTrue(store.loadAllEmbeddingChunks().isEmpty)
    }

    func testBreakdownExplainsRetainedSpaceAfterClearingFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let compiled = root.appendingPathComponent("compiled", isDirectory: true)
        let workspace = support.appendingPathComponent("workspaces/example", isDirectory: true)

        func write(_ path: String, bytes: Int, under directory: URL? = nil) throws {
            let url = (directory ?? support).appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: bytes).write(to: url)
        }

        try write("attachments/image.png", bytes: 100)
        try write("sessions/chat.json", bytes: 80)
        try write("threads.store", bytes: 60)
        try write("diagnostics/log.txt", bytes: 10)
        try write("workspaces/example/task_board/tasks.json", bytes: 20)
        try write("workspaces/example/attachments/asset.png", bytes: 4)
        try write("workspaces/example/sessions/chat.json", bytes: 6)
        try write("workspaces/example/briefings/document/content.md", bytes: 30)
        try write("settings.json", bytes: 2)
        try write("icon.svg", bytes: 5, under: cache)
        try write("filter", bytes: 15, under: compiled)

        let service = CacheStorageService(
            appSupportRoot: support, cacheRoot: cache, compiledCacheRoots: [compiled]
        )
        let before = await service.breakdown()
        XCTAssertEqual(before.attachments, 104)
        XCTAssertEqual(before.sessions, 86)
        XCTAssertEqual(before.threadDatabase, 60)
        XCTAssertEqual(before.workspaces, 20)
        XCTAssertEqual(before.diagnostics, 10)
        XCTAssertEqual(before.clearableFiles, 50)
        XCTAssertEqual(before.other, 2)
        XCTAssertEqual(before.totalBytes, 332)

        try await service.clearFileCaches(workspaceURLs: [workspace])
        let after = await service.breakdown()
        XCTAssertEqual(after.clearableFiles, 0)
        XCTAssertEqual(after.totalBytes, 282)
        XCTAssertTrue(fileManager.fileExists(atPath: support.appendingPathComponent("attachments/image.png").path))
        XCTAssertTrue(fileManager.fileExists(atPath: support.appendingPathComponent("sessions/chat.json").path))
    }
}
