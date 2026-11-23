import XCTest
import RxCodeCore
@testable import RxCode

/// Covers the Markdown the description editor writes for pasted and dropped
/// files. The destination has to survive round-tripping through a Markdown
/// parser, which is why it is a URL rather than the raw path.
@MainActor
final class MarkdownDescriptionEditorTests: XCTestCase {

    func testImageReferenceUsesEmbedSyntax() {
        let attachment = Attachment(
            type: .image,
            name: "shot.png",
            path: "/tmp/shot.png"
        )
        XCTAssertEqual(
            MarkdownDescriptionEditor.markdownReference(for: attachment),
            "![shot.png](file:///tmp/shot.png)"
        )
    }

    func testNonImageReferenceUsesLinkSyntax() {
        let attachment = Attachment(
            type: .file,
            name: "notes.pdf",
            path: "/tmp/notes.pdf"
        )
        XCTAssertEqual(
            MarkdownDescriptionEditor.markdownReference(for: attachment),
            "[notes.pdf](file:///tmp/notes.pdf)"
        )
    }

    /// A Markdown link destination ends at the first space, so a path with
    /// spaces has to be percent-encoded or the link breaks at render time.
    func testSpacesInPathArePercentEncoded() {
        let attachment = Attachment(
            type: .image,
            name: "my shot.png",
            path: "/tmp/my folder/my shot.png"
        )
        let reference = MarkdownDescriptionEditor.markdownReference(for: attachment)
        XCTAssertEqual(reference, "![my shot.png](file:///tmp/my%20folder/my%20shot.png)")
    }

    func testParenthesizedImagePathSurvivesChipRoundTrip() {
        let path = "/tmp/Screen Shot (1).png"
        let image = Attachment(type: .image, name: "Screen Shot (1).png", path: path)
        let reference = MarkdownDescriptionEditor.markdownReference(for: image)
        var chips = DescriptionAttachmentChips()
        XCTAssertEqual(chips.display(for: reference), "[Image1]")
        XCTAssertEqual(chips.attachment(at: 1)?.path, path)
        XCTAssertEqual(chips.markdown(for: "[Image1]"), reference)
    }

    /// Brackets in a filename would otherwise close the link label early.
    func testBracketsInNameAreEscaped() {
        let attachment = Attachment(
            type: .file,
            name: "report [final].txt",
            path: "/tmp/report.txt"
        )
        XCTAssertEqual(
            MarkdownDescriptionEditor.markdownReference(for: attachment),
            "[report \\[final\\].txt](file:///tmp/report.txt)"
        )
    }

    /// A clipboard image that could not be written to disk still names itself,
    /// so the description records what was pasted instead of an empty link.
    func testAttachmentWithoutPathFallsBackToName() {
        let attachment = Attachment(type: .image, name: "clipboard.png")
        XCTAssertEqual(
            MarkdownDescriptionEditor.markdownReference(for: attachment),
            "![clipboard.png](clipboard.png)"
        )
    }

    // MARK: - Image chips

    func testImageReferencesBecomeChipTokens() {
        var chips = DescriptionAttachmentChips()
        let markdown = "See ![a.png](file:///tmp/a.png) and\n![b.png](file:///tmp/b%20c.png)"
        XCTAssertEqual(chips.display(for: markdown), "See [Image1] and\n[Image2]")
        XCTAssertEqual(chips.markdown(for: "See [Image1] and\n[Image2]"), markdown)
    }

    func testFileChipPreviewsItsFileAndPreservesWebLinks() {
        var chips = DescriptionAttachmentChips()
        let markdown = "[notes.pdf](file:///tmp/notes.pdf) [site](https://x.dev)"
        let display = chips.display(for: markdown)
        XCTAssertEqual(display, "[File: notes.pdf] [site](https://x.dev)")
        XCTAssertEqual(chips.markdown(for: display), markdown)
        let files = chips.attachments(in: display)
        XCTAssertEqual(files.map(\.path), ["/tmp/notes.pdf"])
        XCTAssertEqual(chips.removing(files[0], from: display), " [site](https://x.dev)")
    }

    func testChatDraftKeepsImageOrderAndShowsFilesInPlanSetup() throws {
        let file = Attachment(type: .file, name: "notes.md", path: "/tmp/notes.md")
        let first = Attachment(type: .image, name: "a.png", path: "/tmp/a.png")
        let second = Attachment(type: .image, name: "b.png", path: "/tmp/b.png")
        let markdown = MarkdownDescriptionEditor.markdown(forChatDraft: "[Image2] before [Image1]", files: [file, first, second])
        XCTAssertEqual(markdown, "![b.png](file:///tmp/b.png) before ![a.png](file:///tmp/a.png)\n[notes.md](file:///tmp/notes.md)")
        var chips = DescriptionAttachmentChips()
        let display = chips.display(for: markdown)
        let items = chips.attachments(in: display)
        XCTAssertEqual(items.map(\.name), ["b.png", "a.png", "notes.md"])
        XCTAssertEqual(chips.markdown(for: chips.removing(try XCTUnwrap(items.last), from: display)),
                       "![b.png](file:///tmp/b.png) before ![a.png](file:///tmp/a.png)\n")
    }

    func testDeletingAChipDropsItsReference() {
        var chips = DescriptionAttachmentChips()
        _ = chips.display(for: "![a](file:///tmp/a.png) ![b](file:///tmp/b.png)")
        XCTAssertEqual(chips.markdown(for: " [Image2]"), " ![b](file:///tmp/b.png)")
    }

    func testFilesCarriedFromChatWrapTogetherBelowTheDraft() {
        let files = ["a.md", "b.md"].map { Attachment(type: .file, name: $0, path: "/tmp/" + $0) }
        let markdown = MarkdownDescriptionEditor.markdown(forChatDraft: "One line\nAnother", files: files)
        XCTAssertEqual(markdown, "One line\nAnother\n[a.md](file:///tmp/a.md) [b.md](file:///tmp/b.md)")
    }

    func testUnknownTokenIsKeptVerbatim() {
        let chips = DescriptionAttachmentChips()
        XCTAssertEqual(chips.markdown(for: "[Image7]"), "[Image7]")
    }

    func testSameReferenceReusesItsToken() {
        var chips = DescriptionAttachmentChips()
        let reference = "![a](file:///tmp/a.png)"
        XCTAssertEqual(chips.token(for: reference), "[Image1]")
        XCTAssertEqual(chips.token(for: reference), "[Image1]")
        XCTAssertEqual(chips.attachment(at: 1)?.path, "/tmp/a.png")
    }
}
