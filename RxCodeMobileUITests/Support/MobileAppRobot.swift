import CoreGraphics
import XCTest

/// Page object over the app's accessibility identifiers. Keeps the test cases
/// readable and free of raw `XCUIElement` queries.
@MainActor
struct MobileAppRobot {
    let app: XCUIApplication

    /// Generous timeout — the app gates content behind a ~2s splash plus the
    /// mock snapshot round-trip.
    var timeout: TimeInterval = 25

    // MARK: - Tabs (iPhone)

    /// The legacy `TabView` API exposes tab-bar buttons by their label, not by
    /// an accessibility identifier, so tabs are matched by title. `firstMatch`
    /// guards against the tab bar surfacing more than one element per tab.
    var briefingTab: XCUIElement { app.tabBars.buttons["Briefing"].firstMatch }
    var projectsTab: XCUIElement { app.tabBars.buttons["Projects"].firstMatch }

    // MARK: - Briefing

    var anyBriefingCard: XCUIElement { firstButton(prefix: "briefing-card-") }
    var anyBriefingListCard: XCUIElement { firstButton(prefix: "briefing-list-card-") }
    var briefingListScreen: XCUIElement { element(id: "briefing-list-screen") }
    var briefingDetailScreen: XCUIElement { element(id: "briefing-detail-screen") }
    var anyBriefingThreadRow: XCUIElement { firstButton(prefix: "briefing-thread-row-") }

    // MARK: - Projects / threads

    var anyProjectRow: XCUIElement { firstButton(prefix: "project-row-") }
    var threadListScreen: XCUIElement { element(id: "thread-list-screen") }
    var anyThreadRow: XCUIElement { firstButton(prefix: "thread-row-") }

    // MARK: - Chat

    var chatScreen: XCUIElement { element(id: "chat-screen") }
    var anyTranscriptMessage: XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Assistant reply inside"))
            .firstMatch
    }

    // MARK: - Queries

    private func firstButton(prefix: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// Looks an identifier up across element types — the list/detail "screens"
    /// are scroll views, which surface under different queries by idiom.
    private func element(id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    // MARK: - Actions

    /// Waits for `element`, then taps it.
    ///
    /// Prefers a normal hittable tap (which also lets navigation/splash
    /// animations settle first). If the hittability heuristic never settles —
    /// observed on CI iPad simulators after a device rotation, where elements
    /// render and exist but `isHittable` stays `false` — it falls back to a
    /// coordinate tap on the element's centre, which still delivers a real
    /// touch to the rendered element.
    @discardableResult
    func tap(
        _ element: XCUIElement,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element never appeared: \(description)",
            file: file, line: line
        )
        tapWhenReady(element)
        return element
    }

    /// Taps the leading navigation-bar button (the back button).
    func navigateBack(file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            backButton.waitForExistence(timeout: timeout),
            "Back button never appeared",
            file: file, line: line
        )
        tapWhenReady(backButton)
    }

    /// Taps `element` once it is hittable, or — if hittability never settles —
    /// via a coordinate tap on its centre.
    private func tapWhenReady(_ element: XCUIElement) {
        if waitForHittable(element, timeout: 8) {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Waits up to `timeout` for `element` to report itself hittable. Returns
    /// whether it did — callers use the result to choose a tap strategy rather
    /// than to fail the test.
    @discardableResult
    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Assertions

    func assertExists(
        _ element: XCUIElement,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected to be visible: \(description)",
            file: file, line: line
        )
    }

    /// Waits until `element` is gone — used to confirm a pushed view was popped.
    func assertDisappears(
        _ element: XCUIElement,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result, .completed,
            "Expected to disappear: \(description)",
            file: file, line: line
        )
    }

    /// Asserts the chat screen is shown with at least one message rendered.
    func assertMessagesShown(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            chatScreen.waitForExistence(timeout: timeout),
            "Chat screen was not shown",
            file: file, line: line
        )
        XCTAssertTrue(
            anyTranscriptMessage.waitForExistence(timeout: timeout),
            "Transcript message was not shown",
            file: file, line: line
        )
    }
}
