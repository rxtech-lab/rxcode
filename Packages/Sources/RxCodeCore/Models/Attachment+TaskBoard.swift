import Foundation

// MARK: - Attachment persistence

public extension Attachment {
    /// The same attachment with inlined bytes dropped, for storing in a task
    /// board. `AttachmentFactory.fromFileURL` eagerly reads image data into
    /// memory, and persisting that as base64 would bloat the board JSON for no
    /// benefit — the file is still on disk and is re-read at send time.
    ///
    /// Attachments with no `path` (a pasted clipboard image, which exists only
    /// in memory until `resolvingClipboardImages` writes it out) are returned
    /// unchanged, since dropping their data would lose the image entirely.
    func persistableInTaskBoard() -> Attachment {
        guard !path.isEmpty else { return self }
        return Attachment(
            id: id,
            type: type,
            name: name,
            path: path,
            fileSize: fileSize,
            textContent: textContent,
            imageData: nil
        )
    }
}
