import Testing
@testable import RxCodeCore

@Suite("SessionRowReconciler")
struct SessionRowReconcilerTests {

    // MARK: - Resume / known sid

    @Test("Resume of a known sid is a noop")
    func resumeKnownSidIsNoop() {
        let action = SessionRowReconciler.decide(
            newSid: "sid-A",
            previousKey: "sid-A",
            existingIds: ["sid-A", "sid-B"],
            firstUserMessageContent: "anything"
        )
        #expect(action == .noop)
    }

    // MARK: - Mid-stream sid change (the regression case)

    @Test("Compaction-style sid change renames the previous row in place")
    func compactionRenamesPreviousRow() {
        // Stream started under `sid-A`; CLI emitted a `compact_boundary` system
        // event with a fresh `sid-B`. Before the fix, this inserted an empty
        // 'New Session' row keyed by `sid-B`; the fix is to rename `sid-A` →
        // `sid-B` so we don't accumulate empty rows.
        let action = SessionRowReconciler.decide(
            newSid: "sid-B",
            previousKey: "sid-A",
            existingIds: ["sid-A"],
            firstUserMessageContent: "fix the bug"
        )
        #expect(action == .renameInPlace(from: "sid-A", to: "sid-B"))
    }

    @Test("Renaming wins even when no first-user-message content is available")
    func renameRunsWithoutContent() {
        // The previous-row migration shouldn't depend on having scanned a user
        // message — the row already exists with whatever title it carries.
        let action = SessionRowReconciler.decide(
            newSid: "sid-B",
            previousKey: "sid-A",
            existingIds: ["sid-A"],
            firstUserMessageContent: nil
        )
        #expect(action == .renameInPlace(from: "sid-A", to: "sid-B"))
    }

    // MARK: - Unknown sid, no row to migrate

    @Test("Unknown sid with no prior row and no user content is a noop")
    func unknownSidEmptyMessagesIsNoop() {
        // Most important guard for the bug: never persist an empty row when
        // we have no real content yet — `saveSession` will create it later.
        let action = SessionRowReconciler.decide(
            newSid: "sid-X",
            previousKey: "sid-X",
            existingIds: [],
            firstUserMessageContent: nil
        )
        #expect(action == .noop)
    }

    @Test("Unknown sid with whitespace-only user content is a noop")
    func unknownSidWhitespaceContentIsNoop() {
        let action = SessionRowReconciler.decide(
            newSid: "sid-X",
            previousKey: "sid-X",
            existingIds: [],
            firstUserMessageContent: "   \n  "
        )
        #expect(action == .noop)
    }

    @Test("Unknown sid with real content inserts a row titled from the message")
    func unknownSidWithContentInsertsTitledRow() {
        let action = SessionRowReconciler.decide(
            newSid: "sid-X",
            previousKey: "sid-X",
            existingIds: [],
            firstUserMessageContent: "fix the bug"
        )
        #expect(action == .insertNew(id: "sid-X", title: "fix the bug"))
    }

    @Test("Attachment markers in the message are stripped before titling")
    func attachmentMarkersStrippedFromInsertedTitle() {
        let content = "[Attached image: /var/folders/abc.png] fix the bug"
        let action = SessionRowReconciler.decide(
            newSid: "sid-X",
            previousKey: "sid-X",
            existingIds: [],
            firstUserMessageContent: content
        )
        #expect(action == .insertNew(id: "sid-X", title: "fix the bug"))
    }
}

@Suite("ChatSession.placeholderTitle")
struct ChatSessionPlaceholderTitleTests {

    @Test("Empty content returns the default title")
    func emptyReturnsDefault() {
        #expect(ChatSession.placeholderTitle(from: "") == ChatSession.defaultTitle)
        #expect(ChatSession.placeholderTitle(from: "   \n ") == ChatSession.defaultTitle)
    }

    @Test("Attachment marker alone strips to the default title")
    func attachmentOnlyReturnsDefault() {
        #expect(ChatSession.placeholderTitle(from: "[Attached image: /tmp/a.png]") == ChatSession.defaultTitle)
        #expect(ChatSession.placeholderTitle(from: "[Pasted text: lots of stuff]") == ChatSession.defaultTitle)
        #expect(ChatSession.placeholderTitle(from: "[Link: https://example.com]") == ChatSession.defaultTitle)
        #expect(ChatSession.placeholderTitle(from: "[Image1]") == ChatSession.defaultTitle)
    }

    @Test("Strips [ImageN] tokens and [Attached image] markers from the prefix")
    func stripsImageTokensAndAttachedImage() {
        let input = "[Attached image: /var/folders/nl/rxcode-img.png]\n\n[Image1] remove the status bar"
        #expect(ChatSession.placeholderTitle(from: input) == "remove the status bar")
    }

    @Test("Long content is truncated at 50 chars with an ellipsis")
    func longContentTruncated() {
        let long = String(repeating: "a", count: 80)
        let title = ChatSession.placeholderTitle(from: long)
        #expect(title.hasSuffix("..."))
        #expect(title.count == 53)
    }

    @Test("Short content is returned verbatim")
    func shortContentVerbatim() {
        #expect(ChatSession.placeholderTitle(from: "hello") == "hello")
    }
}
