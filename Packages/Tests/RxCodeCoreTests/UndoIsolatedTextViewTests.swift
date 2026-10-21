#if os(macOS)
import AppKit
import Testing
@testable import RxCodeCore

@MainActor
@Suite("Transient editor undo", .serialized)
struct UndoIsolatedTextViewTests {
    @Test("Text editing supports undo and redo")
    func textUndoAndRedo() throws {
        let editor = UndoIsolatedTextView()
        editor.allowsUndo = true
        editor.string = "draft"
        let manager = try #require(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        editor.insertText(" text", replacementRange: NSRange(location: 5, length: 0))
        editor.breakUndoCoalescing()
        manager.endUndoGrouping()

        #expect(editor.string == "draft text")
        #expect(manager.canUndo)
        manager.undo()
        #expect(editor.string == "draft")
        #expect(manager.canRedo)
        manager.redo()
        #expect(editor.string == "draft text")
        editor.resetUndoHistory()
    }

    @Test("Editors in one window have independent undo managers")
    func independentHistory() throws {
        _ = NSApplication.shared
        let window = NSWindow()
        let first = UndoIsolatedTextView()
        let second = UndoIsolatedTextView()
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        let manager = try #require(first.undoManager)
        #expect(manager !== second.undoManager)
        #expect(manager !== window.undoManager)

        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: first) { _ in }
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        #expect(second.undoManager?.canUndo == false)
        first.resetUndoHistory()
    }

    @Test("Reset clears internal targets and redo before content replacement")
    func resetAllTargets() throws {
        let editor = UndoIsolatedTextView()
        let manager = try #require(editor.undoManager)
        let internalTarget = NSObject()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: internalTarget) { target in
            manager.registerUndo(withTarget: target) { _ in }
        }
        manager.endUndoGrouping()
        editor.resetUndoHistory()
        #expect(!manager.canUndo)

        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: internalTarget) { target in
            manager.registerUndo(withTarget: target) { _ in }
        }
        manager.endUndoGrouping()
        manager.undo()
        #expect(manager.canRedo)
        editor.resetUndoHistory()
        editor.string = "replacement"
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
        #expect(editor.string == "replacement")
    }
}
#endif
