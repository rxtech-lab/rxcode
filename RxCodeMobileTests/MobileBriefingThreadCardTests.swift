import XCTest
import SwiftUI
import ViewInspector
import RxCodeSync
@testable import RxCodeMobile

@MainActor
final class MobileBriefingThreadCardTests: XCTestCase {

    func testStreamingThreadShowsLoadingBadge() throws {
        let view = MobileBriefingThreadCardPreview(isStreaming: true)

        let labels = try view.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains("Response in progress"),
            "Mobile briefing rows must show loading state for streaming threads. Labels: \(labels)"
        )
    }

    func testIdleThreadHidesLoadingBadge() throws {
        let view = MobileBriefingThreadCardPreview(isStreaming: false)

        let labels = try view.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertFalse(
            labels.contains("Response in progress"),
            "Finished mobile briefing rows should keep the updated-at label instead of a loading badge. Labels: \(labels)"
        )
    }
}

private struct MobileBriefingThreadCardPreview: View {
    @Namespace private var namespace
    let isStreaming: Bool

    var body: some View {
        MobileBriefingThreadCard(
            thread: MobileThreadSummary(
                sessionId: "thread-1",
                projectId: UUID(),
                branch: "main",
                title: "Streaming thread",
                summary: "Summary",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            isStreaming: isStreaming,
            namespace: namespace
        )
    }
}
