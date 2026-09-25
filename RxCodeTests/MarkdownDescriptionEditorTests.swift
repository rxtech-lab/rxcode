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
        var chips = DescriptionImageChips()
        let markdown = "See ![a.png](file:///tmp/a.png) and\n![b.png](file:///tmp/b%20c.png)"
        XCTAssertEqual(chips.display(for: markdown), "See [Image1] and\n[Image2]")
        XCTAssertEqual(chips.markdown(for: "See [Image1] and\n[Image2]"), markdown)
    }

    /// Links and web links stay as text; only image embeds become chips.
    func testNonImageLinksAreLeftAsText() {
        var chips = DescriptionImageChips()
        let markdown = "[notes.pdf](file:///tmp/notes.pdf) [site](https://x.dev)"
        XCTAssertEqual(chips.display(for: markdown), markdown)
    }

    func testDeletingAChipDropsItsReference() {
        var chips = DescriptionImageChips()
        _ = chips.display(for: "![a](file:///tmp/a.png) ![b](file:///tmp/b.png)")
        XCTAssertEqual(chips.markdown(for: " [Image2]"), " ![b](file:///tmp/b.png)")
    }

    func testUnknownTokenIsKeptVerbatim() {
        let chips = DescriptionImageChips()
        XCTAssertEqual(chips.markdown(for: "[Image7]"), "[Image7]")
    }

    func testSameReferenceReusesItsToken() {
        var chips = DescriptionImageChips()
        let reference = "![a](file:///tmp/a.png)"
        XCTAssertEqual(chips.token(for: reference), "[Image1]")
        XCTAssertEqual(chips.token(for: reference), "[Image1]")
        XCTAssertEqual(chips.url(forChip: 1), URL(fileURLWithPath: "/tmp/a.png"))
    }
}
