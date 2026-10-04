import Testing
@testable import RxCodeCore

@Suite("Scheduled task draft suggestions")
struct ScheduledTaskDraftSuggestionTests {
    @Test("Parses a fenced scheduled task draft")
    func parsesDraft() {
        let raw = """
        ```json
        {"name":"Weekday dependency check","prompt":"Check for outdated dependencies.","cronExpression":"0 9 * * 1-5"}
        ```
        """
        let draft = ScheduledTaskDraftSuggestion.parse(raw)
        #expect(draft?.name == "Weekday dependency check")
        #expect(draft?.prompt == "Check for outdated dependencies.")
        #expect(draft?.cronExpression == "0 9 * * 1-5")
    }

    @Test("Rejects drafts with blank fields or an invalid schedule")
    func rejectsIncompleteDraft() {
        #expect(ScheduledTaskDraftSuggestion.parse(#"{"name":" ","prompt":"Run","cronExpression":"0 9 * * *"}"#) == nil)
        #expect(ScheduledTaskDraftSuggestion.parse(#"{"name":"Check","prompt":"","cronExpression":"0 9 * * *"}"#) == nil)
        #expect(ScheduledTaskDraftSuggestion.parse(#"{"name":"Check","prompt":"Run","cronExpression":"every day"}"#) == nil)
    }
}
