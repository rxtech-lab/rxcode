import Testing
@testable import RxCodeCore

@Suite("Markdown stripping for notification banners")
struct MarkdownStrippingTests {
    @Test("Strips bold and italic markers")
    func stripsEmphasis() {
        #expect(stripMarkdown("Added a **new feature** today") == "Added a new feature today")
        #expect(stripMarkdown("This is *important* work") == "This is important work")
        #expect(stripMarkdown("Use __strong__ and _emphasis_") == "Use strong and emphasis")
    }

    @Test("Preserves snake_case and arithmetic")
    func preservesNonMarkdownUnderscoresAndStars() {
        #expect(stripMarkdown("Renamed user_session_id") == "Renamed user_session_id")
        #expect(stripMarkdown("Computed 2 * 3 inline") == "Computed 2 * 3 inline")
    }

    @Test("Strips ATX headings")
    func stripsHeadings() {
        #expect(stripMarkdown("## Done") == "Done")
        #expect(stripMarkdown("### Summary of changes") == "Summary of changes")
    }

    @Test("Strips inline and fenced code")
    func stripsCode() {
        #expect(stripMarkdown("Fixed the `edge case` handler") == "Fixed the edge case handler")
        let fenced = """
        Here is code:
        ```swift
        let x = 1
        ```
        """
        #expect(stripMarkdown(fenced) == "Here is code: let x = 1")
    }

    @Test("Strips links and images to their text")
    func stripsLinksAndImages() {
        #expect(stripMarkdown("See [the docs](https://example.com)") == "See the docs")
        #expect(stripMarkdown("![diagram](img.png) attached") == "diagram attached")
    }

    @Test("Strips blockquotes, list markers and rules")
    func stripsBlockStructure() {
        #expect(stripMarkdown("> quoted note") == "quoted note")
        #expect(stripMarkdown("- first\n- second") == "first second")
        #expect(stripMarkdown("1. step one\n2. step two") == "step one step two")
        #expect(stripMarkdown("Above\n---\nBelow") == "Above Below")
    }

    @Test("Strips strikethrough")
    func stripsStrikethrough() {
        #expect(stripMarkdown("This was ~~removed~~ cleanly") == "This was removed cleanly")
    }

    @Test("Collapses multi-line text into a single line")
    func collapsesToSingleLine() {
        #expect(stripMarkdown("Line one\n\nLine two") == "Line one Line two")
    }

    @Test("Leaves an unbalanced bold marker from a sentence slice intact-ish")
    func handlesUnbalancedMarkers() {
        // A first-sentence slice can cut a **bold** span; the result must not crash
        // and should still be readable.
        let result = stripMarkdown("Refactored the **auth")
        #expect(result.contains("Refactored the"))
        #expect(result.contains("auth"))
    }

    @Test("Plain text passes through unchanged")
    func plainTextUnchanged() {
        #expect(stripMarkdown("Just a normal sentence.") == "Just a normal sentence.")
    }
}
