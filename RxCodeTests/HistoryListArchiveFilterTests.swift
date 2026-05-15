import XCTest
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCode

/// Guards the contract that the History sidebar hides sessions whose
/// `isArchived` flag does not match the current `showArchived` toggle.
///
/// Two layers of coverage:
///
/// 1. Direct unit tests of `HistoryListView.filteredSummaries(...)` — the pure
///    function that drives every row the sidebar renders. If the filter
///    excludes archived summaries, the view physically cannot render a row
///    for them.
///
/// 2. ViewInspector tests against `ArchiveFilterPreview`, a small helper view
///    that pipes the same filter through a `List` of `TypewriterTitleText`.
///    These verify that the filtered slice is what actually reaches the
///    rendered SwiftUI tree.
///
/// The reason we don't `.inspect()` `HistoryListView` directly: ViewInspector
/// 0.10.3 cannot resolve `@Environment(MyObservable.self)` values through
/// `.environment(_:)` modifiers during body evaluation, which crashes with
/// "No Observable object of type WindowState found." The preview below has
/// no environment dependencies, so the inspector can walk its body cleanly.
@MainActor
final class HistoryListArchiveFilterTests: XCTestCase {

    // MARK: - Pure filter behavior

    func testFilter_currentProjectScope_excludesArchivedWhenShowArchivedFalse() {
        let projectId = UUID()
        let active = summary(id: "a", projectId: projectId, title: "Active", isArchived: false)
        let archived = summary(id: "b", projectId: projectId, title: "Archived", isArchived: true)

        let result = HistoryListView.filteredSummaries(
            from: [active, archived],
            projectId: projectId,
            showArchived: false
        )

        XCTAssertEqual(
            result.map(\.id),
            ["a"],
            "Active History list must drop archived summaries for the current project"
        )
    }

    func testFilter_currentProjectScope_includesOnlyArchivedWhenShowArchivedTrue() {
        let projectId = UUID()
        let active = summary(id: "a", projectId: projectId, title: "Active", isArchived: false)
        let archived = summary(id: "b", projectId: projectId, title: "Archived", isArchived: true)

        let result = HistoryListView.filteredSummaries(
            from: [active, archived],
            projectId: projectId,
            showArchived: true
        )

        XCTAssertEqual(
            result.map(\.id),
            ["b"],
            "Archived view must drop active summaries for the current project"
        )
    }

    func testFilter_currentProjectScope_excludesOtherProjects() {
        let projectId = UUID()
        let otherProjectId = UUID()
        let inScope = summary(id: "a", projectId: projectId, title: "Mine", isArchived: false)
        let otherProject = summary(id: "b", projectId: otherProjectId, title: "Theirs", isArchived: false)

        let result = HistoryListView.filteredSummaries(
            from: [inScope, otherProject],
            projectId: projectId,
            showArchived: false
        )

        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testFilter_allProjectsScope_dropsArchivedAcrossProjects() {
        let projectA = UUID()
        let projectB = UUID()
        let summaries = [
            summary(id: "a-active", projectId: projectA, title: "A", isArchived: false),
            summary(id: "a-archived", projectId: projectA, title: "Aa", isArchived: true),
            summary(id: "b-active", projectId: projectB, title: "B", isArchived: false),
            summary(id: "b-archived", projectId: projectB, title: "Bb", isArchived: true),
        ]

        let result = HistoryListView.filteredSummaries(
            from: summaries,
            projectId: nil,
            showArchived: false
        )

        XCTAssertEqual(Set(result.map(\.id)), ["a-active", "b-active"])
    }

    func testFilter_allProjectsScope_dropsActiveWhenShowArchivedTrue() {
        let projectA = UUID()
        let projectB = UUID()
        let summaries = [
            summary(id: "a-active", projectId: projectA, title: "A", isArchived: false),
            summary(id: "a-archived", projectId: projectA, title: "Aa", isArchived: true),
            summary(id: "b-active", projectId: projectB, title: "B", isArchived: false),
            summary(id: "b-archived", projectId: projectB, title: "Bb", isArchived: true),
        ]

        let result = HistoryListView.filteredSummaries(
            from: summaries,
            projectId: nil,
            showArchived: true
        )

        XCTAssertEqual(Set(result.map(\.id)), ["a-archived", "b-archived"])
    }

    func testFilter_pinnedSummariesAlwaysSortFirst_withinSameArchiveBucket() {
        let projectId = UUID()
        let now = Date()
        let pinnedOld = summary(
            id: "pinned", projectId: projectId, title: "Pinned",
            isArchived: false, isPinned: true,
            updatedAt: now.addingTimeInterval(-1000)
        )
        let recentActive = summary(
            id: "recent", projectId: projectId, title: "Recent",
            isArchived: false, isPinned: false,
            updatedAt: now
        )

        let result = HistoryListView.filteredSummaries(
            from: [recentActive, pinnedOld],
            projectId: projectId,
            showArchived: false
        )

        XCTAssertEqual(
            result.map(\.id),
            ["pinned", "recent"],
            "Within the active bucket, pinned must sort before unpinned regardless of recency"
        )
    }

    // MARK: - ViewInspector — rendered list reflects the filter

    func testInspector_activeView_doesNotRenderArchivedTitle() throws {
        let projectId = UUID()
        let preview = ArchiveFilterPreview(
            summaries: [
                summary(id: "a", projectId: projectId, title: "Active Chat", isArchived: false),
                summary(id: "b", projectId: projectId, title: "Archived Chat", isArchived: true),
            ],
            projectId: projectId,
            showArchived: false
        )

        let titles = try renderedTitles(in: preview)

        XCTAssertTrue(
            titles.contains("Active Chat"),
            "Active sessions must reach the rendered list. Titles: \(titles)"
        )
        XCTAssertFalse(
            titles.contains("Archived Chat"),
            "Archived sessions must NOT render in the sidebar when showArchived=false. Titles: \(titles)"
        )
    }

    func testInspector_archivedView_doesNotRenderActiveTitle() throws {
        let projectId = UUID()
        let preview = ArchiveFilterPreview(
            summaries: [
                summary(id: "a", projectId: projectId, title: "Active Chat", isArchived: false),
                summary(id: "b", projectId: projectId, title: "Archived Chat", isArchived: true),
            ],
            projectId: projectId,
            showArchived: true
        )

        let titles = try renderedTitles(in: preview)

        XCTAssertTrue(
            titles.contains("Archived Chat"),
            "Archived sessions must reach the rendered list when toggled on. Titles: \(titles)"
        )
        XCTAssertFalse(
            titles.contains("Active Chat"),
            "Active sessions must NOT render in the Archived view. Titles: \(titles)"
        )
    }

    func testInspector_emptyState_renderedWhenAllSummariesAreArchived() throws {
        let projectId = UUID()
        let preview = ArchiveFilterPreview(
            summaries: [
                summary(id: "a", projectId: projectId, title: "Archived 1", isArchived: true),
                summary(id: "b", projectId: projectId, title: "Archived 2", isArchived: true),
            ],
            projectId: projectId,
            showArchived: false
        )

        let titles = try renderedTitles(in: preview)
        XCTAssertTrue(
            titles.isEmpty,
            "When every summary is archived, the active list must render nothing. Titles: \(titles)"
        )

        let texts = try preview.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
        XCTAssertTrue(
            texts.contains("No chat history"),
            "Empty state copy should match HistoryListView's. Texts: \(texts)"
        )
    }

    func testInspector_allProjectsScope_dropsArchivedAcrossProjects() throws {
        let projectA = UUID()
        let projectB = UUID()
        let preview = ArchiveFilterPreview(
            summaries: [
                summary(id: "a-active", projectId: projectA, title: "Alpha Active", isArchived: false),
                summary(id: "a-archived", projectId: projectA, title: "Alpha Archived", isArchived: true),
                summary(id: "b-active", projectId: projectB, title: "Beta Active", isArchived: false),
                summary(id: "b-archived", projectId: projectB, title: "Beta Archived", isArchived: true),
            ],
            projectId: nil,
            showArchived: false
        )

        let titles = try renderedTitles(in: preview)

        XCTAssertTrue(titles.contains("Alpha Active"))
        XCTAssertTrue(titles.contains("Beta Active"))
        XCTAssertFalse(
            titles.contains("Alpha Archived"),
            "All-projects active list must not contain archived rows. Titles: \(titles)"
        )
        XCTAssertFalse(
            titles.contains("Beta Archived"),
            "All-projects active list must not contain archived rows. Titles: \(titles)"
        )
    }

    // MARK: - Helpers

    private func renderedTitles(in preview: ArchiveFilterPreview) throws -> [String] {
        try preview.inspect()
            .findAll(TypewriterTitleText.self)
            .map { try $0.actualView().title }
    }

    private func summary(
        id: String,
        projectId: UUID,
        title: String,
        isArchived: Bool,
        isPinned: Bool = false,
        updatedAt: Date = Date()
    ) -> ChatSession.Summary {
        ChatSession.Summary(
            id: id,
            projectId: projectId,
            title: title,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            isArchived: isArchived,
            archivedAt: isArchived ? updatedAt : nil
        )
    }
}

// MARK: - Test helper view

/// Minimal stand-in for `HistoryListView`'s session list. Uses the same
/// `filteredSummaries` function and renders titles through `TypewriterTitleText`
/// just like the real row, but takes inputs directly so ViewInspector can walk
/// its body without needing `AppState` / `WindowState` in the environment.
private struct ArchiveFilterPreview: View {
    let summaries: [ChatSession.Summary]
    let projectId: UUID?
    let showArchived: Bool

    private var filtered: [ChatSession.Summary] {
        HistoryListView.filteredSummaries(
            from: summaries,
            projectId: projectId,
            showArchived: showArchived
        )
    }

    var body: some View {
        if filtered.isEmpty {
            // Matches HistoryListView's active-list empty copy so the empty
            // state test asserts against the production string verbatim.
            Text(showArchived ? "No archived chats" : "No chat history")
        } else {
            List(filtered, id: \.id) { summary in
                TypewriterTitleText(
                    title: summary.title.prefix(1).uppercased() + summary.title.dropFirst()
                )
            }
        }
    }
}
