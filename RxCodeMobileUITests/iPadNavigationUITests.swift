import XCTest

/// iPad navigation flows (UI test cases 2 & 4).
///
/// On iPad the app uses a three-column `NavigationSplitView`. Opening a thread
/// swaps in the chat without unwinding navigation, so the list column the user
/// came from stays visible — that persistence is what these tests assert,
/// instead of navigating back as the iPhone tests do.
final class iPadNavigationUITests: XCTestCase {

    /// Case 2: Briefing → briefing detail → thread → messages, and the briefing
    /// list column remains visible (split view keeps context).
    @MainActor
    func testBriefingSplitKeepsListVisible() throws {
        let r = try UITestRunner.launch(.pad, on: self).robot

        // The iPad briefing split view is shown at launch.
        r.tap(r.anyBriefingListCard, "a briefing card in the list column")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.anyBriefingThreadRow, "a thread row in the briefing detail")
        r.assertMessagesShown()

        // The chat is pushed inside the detail column; the briefing list column
        // stays on screen — the split view never lost the briefing context.
        r.assertExists(r.briefingListScreen, "briefing list column still visible")
    }

    /// Briefing split → briefing detail → New Thread → compose → send → chat
    /// for the new thread is shown in the detail column, the briefing list
    /// column stays visible, and the chat keeps its content after the desktop
    /// snapshot settles (the empty-chat-after-creation regression).
    @MainActor
    func testNewThreadFromBriefingSplitOpensChat() throws {
        let r = try UITestRunner.launch(.pad, on: self).robot

        r.tap(r.anyBriefingListCard, "a briefing card in the list column")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.briefingDetailNewThreadButton, "new thread button in briefing detail")
        r.createNewThread(with: "Help me investigate the empty chat bug.")

        // The chat appears in the detail column and the briefing list column
        // stays alongside it — the split view never lost the briefing context.
        r.assertMessagesShown()
        r.assertExists(r.briefingListScreen, "briefing list column still visible")
        // Sustain the chat for a beat so a delayed snapshot can't quietly
        // navigate us into the projects split.
        Thread.sleep(forTimeInterval: 2.0)
        r.assertExists(r.chatScreen, "chat screen remains after snapshot settles")
        r.assertExists(r.briefingListScreen, "briefing list column still visible after settle")
    }

    /// Case 4: Projects → project → thread list → thread → messages, and the
    /// thread list column remains visible (split view keeps context).
    @MainActor
    func testProjectsSplitKeepsThreadListVisible() throws {
        let r = try UITestRunner.launch(.pad, on: self).robot

        // Selecting a project in the sidebar switches to the projects split view.
        r.tap(r.anyProjectRow, "a project row in the sidebar")
        r.assertExists(r.threadListScreen, "thread list column")

        r.tap(r.anyThreadRow, "a thread row")
        r.assertMessagesShown()

        // The chat fills the detail column; the thread list column stays visible.
        r.assertExists(r.threadListScreen, "thread list column still visible")
    }
}
