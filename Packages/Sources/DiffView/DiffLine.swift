import Foundation
import SwiftUI

/// A single rendered diff row. Carries the raw text (including any `+` / `-`
/// marker), its semantic kind, and 1-based line numbers for the GitHub-style
/// two-column gutter. Either gutter column may be `nil` — added rows have no
/// pre-edit number, removed rows have no post-edit number, hunk/meta rows have
/// neither.
public nonisolated struct DiffLine: Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        case added
        case removed
        case context
        case hunk
        case meta
    }

    public nonisolated let text: String
    public nonisolated let kind: Kind
    public nonisolated let oldLineNumber: Int?
    public nonisolated let newLineNumber: Int?

    public nonisolated init(
        text: String,
        kind: Kind,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        self.text = text
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}
