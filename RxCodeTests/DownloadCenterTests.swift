import XCTest
@testable import RxCode

@MainActor
final class DownloadCenterTests: XCTestCase {
    func testBeginRequestsTheWindowAndListsNewestFirst() {
        let center = DownloadCenter()
        let first = center.begin("Claude Code", kind: .agentRuntime)
        let second = center.begin("Qwen3-8B-4bit", kind: .localModel)
        XCTAssertEqual(center.presentRequest, 2)
        XCTAssertEqual(center.items.map(\.id), [second, first])
        XCTAssertEqual(center.activeCount, 2)
    }

    func testDownloadingReportsAFractionAndInstallingDoesNot() {
        let center = DownloadCenter()
        let id = center.begin("Gemini 1.0", kind: .acpAgent)
        center.update(id, phase: .downloading, receivedBytes: 25, totalBytes: 100)
        XCTAssertEqual(center.items.first?.fraction, 0.25)
        center.update(id, phase: .installing)
        XCTAssertNil(center.items.first?.fraction)
    }

    func testUpdatesAfterCompletionAreIgnored() {
        let center = DownloadCenter()
        let id = center.begin("MLX runtime", kind: .modelRuntime)
        center.finish(id)
        center.update(id, phase: .downloading, receivedBytes: 10)
        XCTAssertEqual(center.items.first?.phase, .finished)
        XCTAssertEqual(center.activeCount, 0)
    }

    func testCancellationErrorsAreReportedAsCancelled() {
        let center = DownloadCenter()
        let cancelled = center.begin("A", kind: .localModel)
        let failed = center.begin("B", kind: .localModel)
        center.fail(cancelled, error: LocalModelDownloader.DownloadError.cancelled)
        center.fail(failed, error: LocalModelDownloader.DownloadError.http(404))
        XCTAssertEqual(center.items.first { $0.id == cancelled }?.phase, .cancelled)
        guard case .failed = center.items.first(where: { $0.id == failed })?.phase else {
            return XCTFail("expected failure")
        }
    }

    func testCancelRunsTheHandlerOnlyWhileActive() {
        let center = DownloadCenter()
        var cancels = 0
        let id = center.begin("Model", kind: .localModel) { cancels += 1 }
        XCTAssertTrue(center.isCancellable(id))
        center.cancel(id)
        XCTAssertEqual(cancels, 1)
        center.fail(id, error: CancellationError())
        XCTAssertFalse(center.isCancellable(id))
        center.cancel(id)
        XCTAssertEqual(cancels, 1)
    }

    func testClearCompletedKeepsActiveItems() {
        let center = DownloadCenter()
        let done = center.begin("Done", kind: .agentRuntime)
        let running = center.begin("Running", kind: .agentRuntime)
        center.finish(done)
        center.clearCompleted()
        XCTAssertEqual(center.items.map(\.id), [running])
        center.remove(running)
        XCTAssertEqual(center.items.count, 1, "active items cannot be removed")
    }

    func testTrackedWorkIsCancellableFromTheWindow() async {
        let started = expectation(description: "operation started")
        let work = Task {
            try await DownloadCenter.track("Codex", kind: .agentRuntime) { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let id = try? XCTUnwrap(DownloadCenter.shared.items.first { $0.title == "Codex" }?.id)
        // The cancel handler is registered right after the item begins.
        for _ in 0..<50 where id.map({ !DownloadCenter.shared.isCancellable($0) }) ?? true {
            try? await Task.sleep(for: .milliseconds(20))
        }
        DownloadCenter.shared.cancelAll()
        do {
            try await work.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(DownloadCenter.shared.items.first { $0.id == id }?.phase, .cancelled)
    }

    func testTrackedFailuresKeepTheirError() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        do {
            try await DownloadCenter.track("Broken", kind: .acpAgent) { _ in throw Boom() }
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(DownloadCenter.shared.items.first { $0.title == "Broken" }?.phase, .failed("boom"))
    }
}
