import os
import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class DownloadCenterTests: XCTestCase {
    func testClearedAgentDownloadsStayClearedAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "downloads.json")
        let center = DownloadCenter(storageURL: url)
        let cancelled = center.begin("Codex", kind: .agentRuntime)
        center.fail(cancelled, error: CancellationError())
        let failed = center.begin("ACP", kind: .acpAgent)
        center.fail(failed, error: URLError(.cannotConnectToHost))
        let finished = center.begin("Claude Code", kind: .agentRuntime)
        center.finish(finished)
        let active = center.begin("Model", kind: .localModel)

        center.remove(cancelled)
        XCTAssertFalse(DownloadCenter(storageURL: url).items.contains { $0.id == cancelled })
        center.clearCompleted()
        // A late completion callback must not recreate a dismissed entry.
        center.finish(failed)
        XCTAssertNil(center.persistenceError)
        XCTAssertEqual(DownloadCenter(storageURL: url).items.map(\.id), [active])
    }

    func testSharedTrackingDoesNotPersistTestFixtures() async throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "RxCode/downloads.json")
        let before = try? Data(contentsOf: url)
        let id = await DownloadCenter.begin("History isolation test", kind: .agentRuntime)
        await DownloadCenter.finish(id)
        DownloadCenter.shared.remove(id)
        XCTAssertEqual(try? Data(contentsOf: url), before)
    }

    func testRelaunchRestoresInterruptedDownloadsAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "downloads.json")
        let summary = HFModelSummary(id: "test/model", author: "test", downloads: 0, likes: 0,
            parameterCount: nil, contextLength: nil, architecture: nil, lastModified: nil)
        let recovery = DownloadCenter.Recovery(summary: summary,
            variant: HFModelVariant(files: ["model.gguf"], sizeBytes: 100, quantization: nil),
            directory: root, stagingDirectory: root.appending(path: "staging"))
        let original = DownloadCenter(storageURL: url)
        let id = original.begin("Model", kind: .localModel, recovery: recovery)
        original.update(id, phase: .downloading, receivedBytes: 40, totalBytes: 100)
        let restored = DownloadCenter(storageURL: url)
        XCTAssertEqual(restored.items.first?.phase, .interrupted)
        XCTAssertEqual(restored.items.first?.receivedBytes, 40)
        XCTAssertEqual(restored.items.first?.recovery, recovery)
        XCTAssertFalse(restored.isCancellable(id))
        restored.clearCompleted()
        XCTAssertEqual(restored.items.count, 1, "unfinished downloads remain recoverable")
        let resumedID = restored.begin("Model", kind: .localModel, recovery: recovery)
        XCTAssertEqual(resumedID, id)
        XCTAssertEqual(restored.items.count, 1)
        restored.finish(id)
        XCTAssertEqual(DownloadCenter(storageURL: url).items.first?.phase, .finished)
        restored.clearCompleted()
        XCTAssertTrue(DownloadCenter(storageURL: url).items.isEmpty)
    }

    func testResumeAppendsOnlyMatchingPartialResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "weights")
        let partial = destination.appendingPathExtension("partial")
        try Data("abc".utf8).write(to: partial)
        try "\"revision-1\"".write(to: partial.appendingPathExtension("validator"), atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        _ = try await LocalModelDownloader(configuration: configuration).download(
            URL(string: "https://download.test/range")!, to: destination,
            onTransferProgress: { received, _, transferred in
                XCTAssertEqual(received - transferred, 3, "Retained bytes must never count as network transfer")
            }) { _, _ in }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "abcdef")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testServerIgnoringRangeReplacesPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "weights")
        let partial = destination.appendingPathExtension("partial")
        try Data("old".utf8).write(to: partial)
        try "\"revision-1\"".write(to: partial.appendingPathExtension("validator"), atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        _ = try await LocalModelDownloader(configuration: configuration).download(
            URL(string: "https://download.test/fresh")!, to: destination) { _, _ in }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "abcdef")
    }

    func testResumedSpeedExcludesRetainedBytesAndResetsForNextFile() {
        let center = DownloadCenter()
        let id = center.begin("Model", kind: .localModel)
        let start = Date(timeIntervalSince1970: 1_000)
        center.update(id, phase: .downloading, receivedBytes: 0, now: start)
        center.update(id, phase: .downloading, receivedBytes: 6_000_000_000, transferredBytes: 0, now: start)
        XCTAssertNil(center.bytesPerSecond(id, at: start))
        center.update(id, phase: .downloading, receivedBytes: 6_002_000_000, transferredBytes: 2_000_000, now: start.addingTimeInterval(2))
        XCTAssertEqual(center.bytesPerSecond(id, at: start.addingTimeInterval(2)), 1_000_000)
        center.update(id, phase: .downloading, receivedBytes: 8_000_000_000, transferredBytes: 0, now: start.addingTimeInterval(2.1))
        XCTAssertNil(center.bytesPerSecond(id, at: start.addingTimeInterval(2.1)))
    }

    func testSpeedUsesNewBytesAndExpiresWhenStalled() {
        let center = DownloadCenter()
        let id = center.begin("Model", kind: .localModel)
        let start = Date(timeIntervalSince1970: 1_000)
        center.update(id, phase: .downloading, receivedBytes: 1_000, now: start)
        XCTAssertNil(center.bytesPerSecond(id, at: start))
        center.update(id, phase: .downloading, receivedBytes: 3_000, now: start.addingTimeInterval(2))
        XCTAssertEqual(center.bytesPerSecond(id, at: start.addingTimeInterval(2)), 1_000)
        XCTAssertEqual(center.bytesPerSecond(id, at: start.addingTimeInterval(7)), 0)
        center.update(id, phase: .downloading, receivedBytes: 100, now: start.addingTimeInterval(8))
        XCTAssertNil(center.bytesPerSecond(id, at: start.addingTimeInterval(8)))
        center.update(id, phase: .downloading, receivedBytes: 200, now: start.addingTimeInterval(9))
        XCTAssertEqual(center.bytesPerSecond(id, at: start.addingTimeInterval(9)), 100)
        center.update(id, phase: .installing, now: start.addingTimeInterval(10))
        XCTAssertNil(center.bytesPerSecond(id, at: start.addingTimeInterval(10)))
    }

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

    func testRapidByteUpdatesAreThrottledButCompletionAndPhaseChangesAreNot() {
        let center = DownloadCenter()
        let id = center.begin("Qwen3-8B-4bit", kind: .localModel)
        center.update(id, phase: .downloading, receivedBytes: 10, totalBytes: 100)
        center.update(id, phase: .downloading, receivedBytes: 20)
        XCTAssertEqual(center.items.first?.receivedBytes, 10)
        center.update(id, phase: .downloading, receivedBytes: 100)
        XCTAssertEqual(center.items.first?.receivedBytes, 100)
        center.update(id, phase: .installing)
        XCTAssertEqual(center.items.first?.phase, .installing)
    }

    func testFirstByteUpdateAndNewlyLearnedTotalAreNotThrottled() {
        let center = DownloadCenter()
        let id = center.begin("ACP Client 1.0", kind: .acpAgent)
        let start = Date(timeIntervalSince1970: 1_000)
        center.update(id, phase: .downloading, now: start)
        center.update(id, phase: .downloading, receivedBytes: 50, totalBytes: 500, transferredBytes: 50, now: start.addingTimeInterval(0.05))
        XCTAssertEqual(center.items.first?.receivedBytes, 50)
        XCTAssertEqual(center.items.first?.totalBytes, 500)
        XCTAssertEqual(center.items.first?.fraction, 0.1)
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

    func testACPInstallerReportsDownloadedBytesTotalBytesAndSpeed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archiveData = try Self.makeTestTarGzArchive(in: root, binaryName: "mock-acp", payloadBytes: 256_000)
        ACPChunkedArchiveProtocol.archiveData = archiveData
        defer { ACPChunkedArchiveProtocol.archiveData = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ACPChunkedArchiveProtocol.self]
        let installer = ACPInstallerService(sessionConfiguration: configuration, installRootURL: root.appending(path: "acp-binaries"))

        let binJSON = Data(#"{"archive":"https://acp-download.test/mock-acp.tar.gz","cmd":"./mock-acp"}"#.utf8)
        let bin = try JSONDecoder().decode(ACPBinaryDist.self, from: binJSON)

        let collector = ProgressCollector()
        let title = "MockACP 1.2.3"
        let executablePath = try await installer.install(
            bin,
            registryId: "mock-acp",
            version: "1.2.3",
            displayName: "MockACP"
        ) { update in
            collector.record(update)
        }

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executablePath))
        let updates = collector.snapshot()
        let downloading = updates.filter { $0.phase == .downloading && $0.downloadedBytes > 0 }
        XCTAssertFalse(downloading.isEmpty, "ACP downloads must report live byte progress")
        XCTAssertEqual(downloading.last?.downloadedBytes, Int64(archiveData.count))
        XCTAssertEqual(downloading.last?.expectedBytes, Int64(archiveData.count))
        XCTAssertEqual(downloading.last?.fraction, 1.0)
        XCTAssertTrue(downloading.contains { ($0.bytesPerSecond ?? 0) > 0 },
                      "ACP downloads must report positive download speed per second")
        XCTAssertTrue(updates.contains { $0.phase == .extracting })

        // DownloadCenter should also reflect the downloaded and total bytes for the ACP agent.
        let item = try XCTUnwrap(DownloadCenter.shared.items.first { $0.title == title && $0.kind == .acpAgent })
        XCTAssertEqual(item.phase, .finished)
        XCTAssertEqual(item.receivedBytes, Int64(archiveData.count))
        XCTAssertEqual(item.totalBytes, Int64(archiveData.count))
        DownloadCenter.shared.remove(item.id)
    }

    func testACPVersionSheetTransferLabelIncludesBytesAndSpeed() {
        let initial = ACPInstallerService.Progress(phase: .downloading, downloadedBytes: 0, expectedBytes: nil, bytesPerSecond: nil)
        XCTAssertNil(ACPVersionSheet.transferLabel(for: initial))

        let withoutSpeed = ACPInstallerService.Progress(
            phase: .downloading,
            downloadedBytes: 2_000_000,
            expectedBytes: 10_000_000,
            bytesPerSecond: nil
        )
        XCTAssertEqual(
            ACPVersionSheet.transferLabel(for: withoutSpeed),
            "\(LocalModelFormat.bytes(2_000_000)) of \(LocalModelFormat.bytes(10_000_000))"
        )

        let withSpeed = ACPInstallerService.Progress(
            phase: .downloading,
            downloadedBytes: 5_000_000,
            expectedBytes: 10_000_000,
            bytesPerSecond: 2_500_000
        )
        XCTAssertEqual(
            ACPVersionSheet.transferLabel(for: withSpeed),
            "\(LocalModelFormat.bytes(5_000_000)) of \(LocalModelFormat.bytes(10_000_000)) · \(LocalModelFormat.bytes(2_500_000))/s"
        )

        let unknownTotal = ACPInstallerService.Progress(
            phase: .downloading,
            downloadedBytes: 3_000_000,
            expectedBytes: nil,
            bytesPerSecond: 1_500_000
        )
        XCTAssertEqual(
            ACPVersionSheet.transferLabel(for: unknownTotal),
            "\(LocalModelFormat.bytes(3_000_000)) · \(LocalModelFormat.bytes(1_500_000))/s"
        )
    }

    private static func makeTestTarGzArchive(in root: URL, binaryName: String, payloadBytes: Int) throws -> Data {
        let srcDir = root.appending(path: "archive-src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let binaryURL = srcDir.appending(path: binaryName)
        var script = Data("#!/bin/sh\necho ok\n# ".utf8)
        // Use pseudo-random bytes so gzip doesn't compress the archive down to a tiny single chunk.
        var rng: UInt64 = 0x1234_5678_9ABC_DEF0
        var padding = Data(capacity: payloadBytes)
        for _ in 0..<payloadBytes {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1
            padding.append(UInt8(truncatingIfNeeded: rng >> 33))
        }
        script.append(padding)
        try script.write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let archiveURL = root.appending(path: "fixture.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archiveURL.path, "-C", srcDir.path, binaryName]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return try Data(contentsOf: archiveURL)
    }
}

nonisolated private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ACPInstallerService.Progress] = []

    func record(_ progress: ACPInstallerService.Progress) {
        lock.withLock { items.append(progress) }
    }

    func snapshot() -> [ACPInstallerService.Progress] {
        lock.withLock { items }
    }
}

nonisolated private final class ACPChunkedArchiveProtocol: URLProtocol, @unchecked Sendable {
    private static let archiveStore = OSAllocatedUnfairLock<Data?>(initialState: nil)
    static var archiveData: Data? {
        get { archiveStore.withLock { $0 } }
        set { archiveStore.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "acp-download.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let data = Self.archiveData else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let chunkSize = max(data.count / 4, 1)
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
                if offset < data.count {
                    Thread.sleep(forTimeInterval: 0.12)
                }
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

nonisolated private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "download.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let range = request.url?.path == "/range"
        if range {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=3-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"revision-1\"")
        }
        let data = Data((range ? "def" : "abcdef").utf8)
        var headers = ["Content-Length": String(data.count), "ETag": "\"revision-1\""]
        if range { headers["Content-Range"] = "bytes 3-5/6" }
        let response = HTTPURLResponse(url: request.url!, statusCode: range ? 206 : 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
