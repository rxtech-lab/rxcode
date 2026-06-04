import Testing
@testable import RxCodeChatKit

@Suite("MessageListView scroll policy")
struct MessageListViewScrollPolicyTests {
    @Test("Live assistant updates follow bottom only when already at bottom")
    func liveAssistantUpdatesFollowBottomOnlyWhenAnchored() {
        #expect(MessageListViewScrollPolicy.shouldRequestLiveBottomScroll(wasAtBottom: true))
        #expect(!MessageListViewScrollPolicy.shouldRequestLiveBottomScroll(wasAtBottom: false))
    }
}
