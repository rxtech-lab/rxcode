import RxCodeCore
import SwiftUI
import ViewInspector
import XCTest
@testable import RxCode

@MainActor
final class GitRefBadgeTests: XCTestCase {
    func testTrackedAndLocalOnlyBranchesShareACommit() throws {
        let refs = GitHistoryParser.parseDecorations(
            "HEAD -> refs/heads/main, refs/heads/local-only, refs/remotes/origin/main, tag: refs/tags/v1"
        )
        let badges = GitRefBadges(refs: refs, snapshot: GitRepositorySnapshot(), branchColor: .orange) { _ in }
        let entries = try badges.inspect().forEach()
        XCTAssertEqual(entries.count, 3)
        let main = try entries.hStack(0)
        XCTAssertEqual(try main.find(ViewType.Image.self).actualImage().name(), "GitHubMark")
        XCTAssertEqual(try main.find(text: "main").string(), "main")
        XCTAssertThrowsError(try main.find(text: "origin/main"))
        let local = try entries.hStack(1)
        XCTAssertEqual(try local.find(ViewType.Image.self).actualImage().name(), "arrow.triangle.branch")
        XCTAssertEqual(try local.find(text: "local-only").string(), "local-only")
        XCTAssertEqual(try entries.hStack(2).find(text: "v1").string(), "v1")

        let renderer = ImageRenderer(content: HStack(spacing: 5) { badges }.padding(8).background(ClaudeTheme.surfacePrimary))
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.nsImage))
        attachment.name = "Tracked branch, local branch and tag"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDifferentlyNamedUpstreamAndDivergedTips() throws {
        let remote = GitRemoteBranch(remote: "team/fork", name: "feature/login", tip: "upstream")
        let local = GitRef(kind: .localBranch, name: "review")
        let tracking = GitRef(kind: .remoteBranch, name: remote.refName)
        var snapshot = GitRepositorySnapshot()
        snapshot.remotes = [remote.remote]
        snapshot.remoteBranches = [remote]
        snapshot.localBranches = [
            GitLocalBranch(name: local.name, upstream: remote.refName, ahead: 1, behind: 0, isCurrent: false,
                           tip: "local", upstreamRemote: remote.remote, upstreamRef: "refs/heads/feature/login"),
        ]

        for (refs, title) in [([local, tracking], "review"), ([local], "review"), ([tracking], "feature/login")] {
            let badges = GitRefBadges(refs: refs, snapshot: snapshot) { _ in }
            let entries = try badges.inspect().forEach()
            XCTAssertEqual(entries.count, 1)
            let entry = try entries.hStack(0)
            XCTAssertEqual(try entry.find(ViewType.Image.self).actualImage().name(), "GitHubMark")
            XCTAssertEqual(try entry.find(text: title).string(), title)
            XCTAssertThrowsError(try entry.find(text: remote.refName))
        }
    }

    func testSameNamedRemotesShareAMarkAndKeepTheirCheckoutTargets() throws {
        let refs = GitHistoryParser.parseDecorations("refs/remotes/origin/topic, refs/remotes/fork/topic")
        var selected: GitSidebarItem?
        let badges = GitRefBadges(refs: refs, snapshot: GitRepositorySnapshot()) { selected = $0 }
        let entries = try badges.inspect().forEach()
        XCTAssertEqual(entries.count, 1)
        let entry = try entries.hStack(0)
        XCTAssertEqual(try entry.find(text: "topic").string(), "topic")
        let menu = try entry.find(ViewType.Menu.self)
        for ref in refs {
            try menu.find(button: "Checkout \(ref.name)").tap()
            XCTAssertEqual(selected, .remoteBranch(ref.name))
        }
    }
}
