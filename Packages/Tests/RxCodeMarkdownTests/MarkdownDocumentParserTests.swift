import Foundation
import Testing
@testable import RxCodeMarkdown

struct MarkdownDocumentParserTests {
    @Test("Parser recognizes common markdown block components")
    func parsesCommonBlocks() {
        let document = MarkdownDocumentParser.parse("""
        # Title

        Paragraph with **bold** and [link](https://example.com).

        > Quoted text

        - One
        - Two

        | Name | Value |
        | --- | --- |
        | Files | 10 |

        ```swift
        let value = 1
        ```

        ![Alt](https://example.com/image.png)

        ---
        """)

        #expect(document.blocks.count == 8)

        guard case .heading(let level, let headingInlines, _) = document.blocks[0] else {
            Issue.record("Expected heading block")
            return
        }
        #expect(level == 1)
        #expect(headingInlines == [.text("Title", range: 2..<7)])

        guard case .paragraph(let paragraphInlines, _) = document.blocks[1] else {
            Issue.record("Expected paragraph block")
            return
        }
        #expect(paragraphInlines.contains(.strong("bold", range: 24..<32)))
        #expect(paragraphInlines.contains(.link(label: "link", destination: "https://example.com", range: 37..<64)))

        guard case .list(let ordered, let items, _) = document.blocks[3] else {
            Issue.record("Expected list block")
            return
        }
        #expect(!ordered)
        #expect(items.count == 2)

        guard case .table(let headers, let rows, _) = document.blocks[4] else {
            Issue.record("Expected table block")
            return
        }
        #expect(headers == ["Name", "Value"])
        #expect(rows == [["Files", "10"]])

        guard case .codeBlock(let language, let content, _) = document.blocks[5] else {
            Issue.record("Expected code block")
            return
        }
        #expect(language == "swift")
        #expect(content == "let value = 1")
    }

    @Test("Inline parser recognizes links, bare URLs, code, and images")
    func parsesInlineComponents() {
        let inlines = MarkdownDocumentParser.parseInlines(
            "Open [docs](docs/index.md), `code`, https://example.com, and ![alt](image.png)",
            baseOffset: 10
        )

        #expect(inlines.contains(.link(label: "docs", destination: "docs/index.md", range: 15..<36)))
        #expect(inlines.contains(.code("code", range: 38..<44)))
        #expect(inlines.contains(.link(label: "https://example.com", destination: "https://example.com", range: 46..<65)))
        #expect(inlines.contains(.image(alt: "alt", source: "image.png", range: 71..<88)))
    }

    @Test("Relative image URLs resolve against the supplied base URL")
    func resolvesRelativeURLs() {
        let baseURL = URL(fileURLWithPath: "/tmp/docs/guide.md")
        let resolved = MarkdownDocumentParser.resolvedURL(for: "assets/image.png", baseURL: baseURL)

        #expect(resolved == URL(fileURLWithPath: "/tmp/docs/assets/image.png"))
    }

    @Test("Absolute URLs are preserved")
    func preservesAbsoluteURLs() {
        let resolved = MarkdownDocumentParser.resolvedURL(for: "https://example.com/image.png", baseURL: nil)

        #expect(resolved == URL(string: "https://example.com/image.png"))
    }

    @Test("Absolute local paths resolve as file URLs")
    func resolvesAbsoluteLocalPathsAsFileURLs() {
        let resolved = MarkdownDocumentParser.resolvedURL(
            for: "/Users/example/Application Support/RxCode/file.swift:12",
            baseURL: nil
        )

        #expect(resolved == URL(fileURLWithPath: "/Users/example/Application Support/RxCode/file.swift:12"))
        #expect(resolved?.isFileURL == true)
    }

    @Test("Fade splitter keeps existing prefix opaque when text is appended inside one inline run")
    func splitsInlineRunAtFadeBoundary() {
        let parts = MarkdownFadeSplitter.split(
            "Existing new",
            range: 0..<12,
            fadeSegments: [
                MarkdownFadeSegment(range: 8..<12, opacity: 0.4),
            ]
        )

        #expect(parts == [
            MarkdownFadePart(value: "Existing", shouldFade: false),
            MarkdownFadePart(value: " new", shouldFade: true, opacity: 0.4),
        ])
    }

    @Test("Fade splitter does not fade runs entirely before the boundary")
    func keepsExistingRunOpaque() {
        let parts = MarkdownFadeSplitter.split(
            "Existing",
            range: 0..<8,
            fadeSegments: [
                MarkdownFadeSegment(range: 8..<12, opacity: 0.4),
            ]
        )

        #expect(parts == [
            MarkdownFadePart(value: "Existing", shouldFade: false),
        ])
    }

    @Test("Fade splitter handles multiple active fade ranges")
    func splitsMultipleFadeRanges() {
        let parts = MarkdownFadeSplitter.split(
            "Existing new more",
            range: 0..<17,
            fadeSegments: [
                MarkdownFadeSegment(range: 9..<12, opacity: 0.5),
                MarkdownFadeSegment(range: 13..<17, opacity: 0.2),
            ]
        )

        #expect(parts == [
            MarkdownFadePart(value: "Existing ", shouldFade: false),
            MarkdownFadePart(value: "new", shouldFade: true, opacity: 0.5),
            MarkdownFadePart(value: " ", shouldFade: false),
            MarkdownFadePart(value: "more", shouldFade: true, opacity: 0.2),
        ])
    }

    @Test("Fade splitter clamps source ranges longer than visible text")
    func clampsMismatchedSourceAndVisibleRanges() {
        let parts = MarkdownFadeSplitter.split(
            "link",
            range: 0..<19,
            fadeSegments: [
                MarkdownFadeSegment(range: 1..<5, opacity: 0.3),
            ]
        )

        #expect(parts == [
            MarkdownFadePart(value: "l", shouldFade: false),
            MarkdownFadePart(value: "ink", shouldFade: true, opacity: 0.3),
        ])
    }

    @Test("Text differ returns only the appended range")
    func detectsAppendedRange() {
        let range = MarkdownTextDiffer.insertedRange(
            from: "Existing",
            to: "Existing new"
        )

        #expect(range == 8..<12)
    }

    @Test("Text differ preserves unchanged suffix around an insertion")
    func detectsInsertedRangeBeforeSuffix() {
        let range = MarkdownTextDiffer.insertedRange(
            from: "Hello world",
            to: "Hello new world"
        )

        #expect(range == 6..<10)
    }
}
