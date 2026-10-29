import Testing
@testable import RxCodeCore

@Suite("AskUserQuestion follow-up prompt")
struct AskUserQuestionFollowUpTests {
    private let questions = [
        AskUserQuestion.Question(id: "0", question: "Which database?", header: "DB", multiSelect: false, options: []),
        AskUserQuestion.Question(id: "1", question: "Which platforms?", header: nil, multiSelect: true, options: []),
        AskUserQuestion.Question(id: "2", question: "Skipped?", header: nil, multiSelect: false, options: []),
    ]

    @Test func pairsEachAnsweredQuestionWithItsAnswer() {
        let prompt = AskUserQuestion.followUpPrompt(
            questions: questions,
            answers: [0: .single("Postgres"), 1: .multi(["iOS", "macOS"])]
        )
        #expect(prompt == "You asked: Which database?\nMy answer: Postgres\n\nYou asked: Which platforms?\nMy answer: iOS, macOS")
    }

    @Test func isEmptyWithoutAnswers() {
        #expect(AskUserQuestion.followUpPrompt(questions: questions, answers: [:]).isEmpty)
    }
}
