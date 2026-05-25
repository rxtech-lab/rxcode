import XCTest

/// iPhone navigation flows (UI test cases 1 & 3).
///
/// On iPhone the app uses a `TabView` with `NavigationStack` tabs, so each flow
/// pushes a detail screen and navigates back with the navigation-bar back button.
final class iPhoneNavigationUITests: XCTestCase {

    /// Case 1: Briefing tab → briefing detail → thread → messages → back →
    /// briefing detail is shown again.
    @MainActor
    func testBriefingFlowReturnsToDetailAfterBack() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.briefingTab, "Briefing tab")
        r.tap(r.anyBriefingCard, "a briefing card")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.anyBriefingThreadRow, "a thread row in the briefing detail")
        r.assertMessagesShown()

        r.navigateBack()
        r.assertExists(r.briefingDetailScreen, "briefing detail screen after back")
        r.assertDisappears(r.chatScreen, "chat screen after navigating back")
    }

    /// Briefing tab → briefing detail → New Thread → compose → send → chat for
    /// the new thread is shown and remains shown after the desktop snapshot
    /// settles (the empty-chat-after-creation regression).
    @MainActor
    func testNewThreadFromBriefingDetailOpensChat() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.briefingTab, "Briefing tab")
        r.tap(r.anyBriefingCard, "a briefing card")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.briefingDetailNewThreadButton, "new thread button in briefing detail")
        r.createNewThread(with: "Help me investigate the empty chat bug.")

        // The chat screen for the freshly-created thread must appear and
        // remain populated — i.e. the briefing navigation stack should hold
        // it, not get reset by the snapshot-driven `activeSessionID` change.
        r.assertMessagesShown()
        // Sustain the assertion a bit so a delayed snapshot can't pop us off.
        Thread.sleep(forTimeInterval: 2.0)
        r.assertExists(r.chatScreen, "chat screen remains after snapshot settles")
        r.assertMessagesShown()
    }

    /// Case 3: Projects tab → project → thread list → thread → messages → back →
    /// thread list is shown again.
    @MainActor
    func testProjectsFlowReturnsToThreadListAfterBack() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.projectsTab, "Projects tab")
        r.tap(r.anyProjectRow, "a project row")
        r.assertExists(r.threadListScreen, "thread list screen")

        r.tap(r.anyThreadRow, "a thread row")
        r.assertMessagesShown()

        r.navigateBack()
        r.assertExists(r.threadListScreen, "thread list screen after back")
        r.assertDisappears(r.chatScreen, "chat screen after navigating back")
    }
}
