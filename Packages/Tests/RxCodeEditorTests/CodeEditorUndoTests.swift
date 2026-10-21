#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import RxCodeEditor

@MainActor
@Suite("Code editor undo lifecycle", .serialized)
struct CodeEditorUndoTests {
    @Test("External document replacement discards previous text undo")
    func replacementClearsUndo() throws {
        let view = CodeEditorView(text: .constant(""), language: "text")
        let coordinator = view.makeCoordinator()
        let editor = CompletionTextView()
        coordinator.textView = editor
        editor.allowsUndo = true
        let manager = try #require(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        editor.insertText("old document", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        manager.endUndoGrouping()
        #expect(manager.canUndo)

        coordinator.apply(text: "new document")
        #expect(editor.string == "new document")
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }

    @Test("Dismantling clears undo records for targets other than the text view")
    func dismantleClearsInternalTargets() throws {
        let view = CodeEditorView(text: .constant(""), language: "text")
        let coordinator = view.makeCoordinator()
        let scrollView = NSScrollView()
        let editor = CompletionTextView()
        scrollView.documentView = editor
        coordinator.textView = editor
        let manager = try #require(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: NSObject()) { _ in
            Issue.record("A dismantled editor must not invoke old undo records")
        }
        manager.endUndoGrouping()

        CodeEditorView.dismantleNSView(scrollView, coordinator: coordinator)
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
        #expect(scrollView.documentView == nil)
        #expect(coordinator.textView == nil)
    }
}
#endif
