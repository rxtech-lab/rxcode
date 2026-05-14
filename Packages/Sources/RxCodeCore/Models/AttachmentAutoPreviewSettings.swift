import Foundation

/// Per-type flags that control whether pasted content is auto-converted to an attachment preview chip.
public struct AttachmentAutoPreviewSettings: Codable, Sendable {
    public var url: Bool = true
    public var filePath: Bool = true
    public var image: Bool = true
    public var longText: Bool = true

    public init() {}
}
