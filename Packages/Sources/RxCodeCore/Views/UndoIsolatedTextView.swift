#if os(macOS)
import AppKit

/// Keeps transient editors' text undo operations out of the window's shared history.
@MainActor
open class UndoIsolatedTextView: NSTextView {
    private let textUndoManager = UndoManager()

    open override var undoManager: UndoManager? { textUndoManager }

    /// Call before replacing the document or dismantling the editor. AppKit can
    /// register internal undo targets, so removing actions for just `self` is insufficient.
    public func resetUndoHistory() {
        breakUndoCoalescing()
        textUndoManager.removeAllActions()
    }
}
#endif
