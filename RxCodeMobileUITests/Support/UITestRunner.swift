import UIKit
import XCTest

/// A launched app under test, paired with the mock relay server feeding it.
@MainActor
struct MockAppSession {
    let app: XCUIApplication
    let server: MockRelayServer

    /// Page object for driving the app's navigation.
    var robot: MobileAppRobot { MobileAppRobot(app: app) }
}

/// Boots the app for a UI test: starts the in-process mock relay server, launches
/// the app in mock mode (skips pairing, points the relay at the mock), and
/// registers teardown.
///
/// Implemented as a free helper rather than an `XCTestCase` subclass so the test
/// classes never override `setUp`/`tearDown` — that keeps them clear of the
/// actor-isolation pitfalls around overriding `nonisolated` XCTest hooks.
@MainActor
enum UITestRunner {

    enum Idiom {
        case phone
        case pad
        /// Runs regardless of device idiom.
        case any
    }

    /// Starts the mock server, launches the app, and registers teardown on
    /// `testCase`. Throws `XCTSkip` when the running simulator's idiom does not
    /// match `idiom`.
    static func launch(
        _ idiom: Idiom,
        on testCase: XCTestCase
    ) throws -> MockAppSession {
        testCase.continueAfterFailure = false

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        switch idiom {
        case .phone:
            try XCTSkipIf(isPad, "iPhone-only test skipped on iPad simulator.")
        case .pad:
            try XCTSkipUnless(isPad, "iPad-only test skipped on iPhone simulator.")
        case .any:
            break
        }

        let server = MockRelayServer(fixtures: .standard())
        try server.start()
        // Stop the server at teardown. `MockRelayServer` is Sendable; the app is
        // re-terminated automatically by the next `XCUIApplication.launch()`.
        testCase.addTeardownBlock {
            server.stop()
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-mock",
            "-uitest-relay-url", server.relayURL,
            "-uitest-desktop-pubkey", server.desktopPublicKeyHex,
        ]
        app.launch()

        // The iPad uses a three-column split view; landscape keeps the sidebar,
        // content, and detail columns all on screen. Rotating after launch, with
        // the app foregrounded, applies more reliably than rotating SpringBoard.
        if isPad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }

        // Wait for the mock snapshot to populate the main UI, then give the
        // launch splash a bounded window to finish fading so the first tap lands
        // on interactive UI. The hittable wait is best-effort: on some CI
        // simulators it never settles, and `MobileAppRobot` handles that with a
        // coordinate-tap fallback.
        let readyMarker = app.staticTexts["Project Alpha"].firstMatch
        XCTAssertTrue(
            readyMarker.waitForExistence(timeout: 30),
            "Main UI never appeared — the mock pairing/snapshot pipeline failed."
        )
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: readyMarker
        )
        _ = XCTWaiter().wait(for: [settled], timeout: 8)

        return MockAppSession(app: app, server: server)
    }
}
