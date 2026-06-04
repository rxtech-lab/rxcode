import XCTest
@testable import RxCode

final class GeneratedTextSanitizerTests: XCTestCase {
    func testCleanMarkdownDocumentUnwrapsFencedMarkdown() {
        let raw = """
        ```markdown
        ### Features
        - Added branch briefing cleanup.
        ```
        """

        XCTAssertEqual(
            GeneratedTextSanitizer.cleanMarkdownDocument(raw),
            """
            ### Features
            - Added branch briefing cleanup.
            """
        )
    }

    func testCleanMarkdownDocumentDropsPersistedLanguageLabel() {
        let raw = """
        markdown
        ### Fixes
        - Hid the stray language marker.
        """

        XCTAssertEqual(
            GeneratedTextSanitizer.cleanMarkdownDocument(raw),
            """
            ### Fixes
            - Hid the stray language marker.
            """
        )
    }

    func testCleanMarkdownDocumentUnwrapsQuotedFencedMarkdown() {
        let raw = """
        "```markdown
        ### Improvements
        - Preserved headings while removing wrappers.
        ```"
        """

        XCTAssertEqual(
            GeneratedTextSanitizer.cleanMarkdownDocument(raw),
            """
            ### Improvements
            - Preserved headings while removing wrappers.
            """
        )
    }

    func testCleanSummaryRejectsProviderErrorsAfterFenceCleanup() {
        let raw = """
        ```text
        Error: model unavailable
        ```
        """

        XCTAssertNil(
            GeneratedTextSanitizer.cleanSummary(
                raw,
                limit: 180,
                errorPrefixes: ["error:"]
            )
        )
    }
}
