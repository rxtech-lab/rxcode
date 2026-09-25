import Testing
@testable import RxCodeCore

@Suite("Story draft suggestions")
struct StoryDraftSuggestionTests {
    @Test("Parses a fenced story and child tasks")
    func parsesDraft() {
        let raw = """
        ```json
        {"title":"Improve search","tasks":[{"title":"Index threads","details":"Include archived threads."},{"title":"Add filters","details":"Filter by project."}]}
        ```
        """
        let draft = StoryDraftSuggestion.parse(raw)
        #expect(draft?.title == "Improve search")
        #expect(draft?.tasks.map(\.title) == ["Index threads", "Add filters"])
        #expect(draft?.tasks.first?.details == "Include archived threads.")
    }

    @Test("Rejects drafts without usable tasks")
    func rejectsIncompleteDraft() {
        #expect(StoryDraftSuggestion.parse(#"{"title":"Search","tasks":[]}"#) == nil)
        #expect(StoryDraftSuggestion.parse(#"{"title":"Search","tasks":[{"title":" ","details":"Work"}]}"#) == nil)
    }
}
