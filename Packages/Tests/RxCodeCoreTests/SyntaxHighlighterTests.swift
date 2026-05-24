import Testing
@testable import RxCodeCore

@Suite("Syntax highlighter")
struct SyntaxHighlighterTests {
    @Test("Handles unterminated strings ending with an escape")
    func handlesUnterminatedStringsEndingWithEscape() {
        let cases = [
            "let single = 'value\\",
            "let double = \"value\\",
            "let triple = \"\"\"value\\",
        ]

        for source in cases {
            #expect(SyntaxHighlighter.highlightNS(source, language: "swift").string == source)
        }
    }
}
