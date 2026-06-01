import Testing
@testable import RxCodeCore

@Suite("ChatSession.stripAttachmentMarkers")
struct StripAttachmentMarkersTests {

    @Test("Strips [Attached image: ...] block")
    func stripsAttachedImage() {
        let input = "[Attached image: /var/folders/nl/rxcode-img-3624AF0E.png] fix the bug"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "fix the bug")
    }

    @Test("Strips [Attached file: ...] block")
    func stripsAttachedFile() {
        let input = "[Attached file: /Users/me/notes.txt]\nsummarize this"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "summarize this")
    }

    @Test("Strips [Pasted text: ...] block")
    func stripsPastedText() {
        let input = "[Pasted text: 1024 chars] explain"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "explain")
    }

    @Test("Strips [Link: ...] block")
    func stripsLink() {
        let input = "[Link: https://example.com] open this"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "open this")
    }

    @Test("Strips [Image1] display token")
    func stripsImage1Token() {
        let input = "[Image1] remove the status bar"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "remove the status bar")
    }

    @Test("Strips multi-digit [ImageN] tokens")
    func stripsMultiDigitImageToken() {
        let input = "compare [Image1] and [Image12] please"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "compare and please")
    }

    @Test("Strips both [Attached image] and [ImageN] in same message")
    func stripsCombined() {
        let input = "[Attached image: /var/folders/nl/rxcode-img.png]\n\n[Image1] remove the status bar's project location"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "remove the status bar's project location")
    }

    @Test("Collapses runs of whitespace")
    func collapsesWhitespace() {
        let input = "[Image1]   hello\n\n\nworld"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "hello world")
    }

    @Test("Empty after stripping returns empty string")
    func emptyAfterStripping() {
        let input = "[Attached image: /tmp/x.png]"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "")
    }

    @Test("Plain text untouched")
    func plainText() {
        let input = "what is swift"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "what is swift")
    }

    @Test("Strips surrounding **bold** markers")
    func stripsBold() {
        let input = "**feat: Complete UI and backend integration**"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "feat: Complete UI and backend integration")
    }

    @Test("Strips inline bold, italic-bold, and code markers")
    func stripsInlineEmphasis() {
        let input = "fix the `parser` and __retry__ logic"
        #expect(ChatSession.stripAttachmentMarkers(from: input) == "fix the parser and retry logic")
    }
}

@Suite("ChatSession.stripMarkdownEmphasis")
struct StripMarkdownEmphasisTests {

    @Test("Removes ** markers, keeps content")
    func removesBold() {
        #expect(ChatSession.stripMarkdownEmphasis(from: "**feat: add release mode**") == "feat: add release mode")
    }

    @Test("Removes __ and backtick markers")
    func removesUnderscoreAndCode() {
        #expect(ChatSession.stripMarkdownEmphasis(from: "__chore__: bump `deps`") == "chore: bump deps")
    }

    @Test("Plain text untouched")
    func plainText() {
        #expect(ChatSession.stripMarkdownEmphasis(from: "feat: add ci status scan") == "feat: add ci status scan")
    }
}

