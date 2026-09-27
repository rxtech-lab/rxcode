import Testing
@testable import RxCodeCore

@Suite("Cron expression suggestions")
struct CronExpressionSuggestionTests {
    @Test("Detects natural-language schedules")
    func detectsNaturalLanguage() {
        #expect(CronExpressionSuggestion.isNaturalLanguage("every weekday at 9am"))
        #expect(CronExpressionSuggestion.isNaturalLanguage("每天9点"))
        #expect(!CronExpressionSuggestion.isNaturalLanguage("0 9 * * 1-5"))
        #expect(!CronExpressionSuggestion.isNaturalLanguage("0 9 * * mon-fri"))
        #expect(!CronExpressionSuggestion.isNaturalLanguage("0 9 * *"))
        #expect(!CronExpressionSuggestion.isNaturalLanguage("0 9 * * mon-fri *"))
        #expect(!CronExpressionSuggestion.isNaturalLanguage("@dayly"))
        #expect(!CronExpressionSuggestion.isNaturalLanguage("  "))
    }

    @Test("Parses the first valid cron line")
    func parsesReply() {
        #expect(CronExpressionSuggestion.parse("```\n0 9 * * 1-5\n```") == "0 9 * * 1-5")
        #expect(CronExpressionSuggestion.parse("Here it is:\n`*/15 * * * *`") == "*/15 * * * *")
        #expect(CronExpressionSuggestion.parse("every day") == nil)
    }
}
