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

    @Test("Keeps starts-after links that point at an earlier task")
    func parsesStartsAfter() {
        let raw = #"""
        {"title":"Search","tasks":[
          {"title":"A","details":"","starts_after":1},
          {"title":"B","details":"","starts_after":1},
          {"title":"C","details":"","starts_after":"2"},
          {"title":"D","starts_after":4},
          {"title":"E","details":"","starts_after":9},
          {"title":"F","details":"","starts_after":null},
          {"title":"G","details":"","starts_after":"x"}
        ]}
        """#
        let draft = StoryDraftSuggestion.parse(raw)
        #expect(draft?.tasks.map(\.startsAfter) == [nil, 0, 1, nil, nil, nil, nil])
        #expect(draft?.tasks[3].details == "")
    }

    @Test("Prompt asks for sequential starts-after links")
    func promptMentionsStartsAfter() {
        #expect(StoryDraftSuggestion.prompt(source: "x").contains("starts_after"))
    }

    @Test("Rejects drafts without usable tasks")
    func rejectsIncompleteDraft() {
        #expect(StoryDraftSuggestion.parse(#"{"title":"Search","tasks":[]}"#) == nil)
        #expect(StoryDraftSuggestion.parse(#"{"title":"Search","tasks":[{"title":" ","details":"Work"}]}"#) == nil)
    }
}
