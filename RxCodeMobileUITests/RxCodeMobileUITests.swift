import XCTest

/// Smoke test for the mock-server pipeline: confirms the app skips pairing,
/// connects to the in-process mock relay, applies the snapshot, and reaches the
/// main UI. Runs on any device idiom.
final class RxCodeMobileUITests: XCTestCase {

    @MainActor
    func testLaunchesPastPairingIntoMainUI() throws {
        let session = try UITestRunner.launch(.any, on: self)

        // A fixture project name on screen proves the whole pipeline worked:
        // launch args → skip pairing → mock relay handshake → snapshot applied.
        XCTAssertTrue(
            session.app.staticTexts["Project Alpha"].waitForExistence(timeout: 25),
            "Main UI never appeared — the mock pairing/snapshot pipeline failed."
        )
    }
}
