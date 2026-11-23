import Foundation

nonisolated extension CodingPlanReview.Edit {
    /// Full-plan revisions have no suggestion fences. Diff their words, keeping
    /// whitespace in the tokens so each hunk round-trips the exact Markdown.
    static func changes(from original: String, to revised: String, comment: String? = nil) -> [Self] {
        guard original != revised else { return [] }
        let notes = comment.flatMap { $0.isEmpty ? nil : [$0] }
        func tokens(_ text: String) -> [Substring] {
            text.ranges(of: #/\s+|\S+\s*/#).map { text[$0] }
        }
        var old = tokens(original)
        var new = tokens(revised)
        // Bound the work for long, substantially rewritten plans.
        if old.count + new.count > 4_000 {
            old = original.ranges(of: #/[^\n]*\n|[^\n]+/#).map { original[$0] }
            new = revised.ranges(of: #/[^\n]*\n|[^\n]+/#).map { revised[$0] }
            if old.count + new.count > 4_000 {
                return [Self(original: original, replacement: revised, offset: 0, userComments: notes)]
            }
        }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var edits: [Self] = []
        var oldIndex = 0, newIndex = 0, offset = 0
        while oldIndex < old.count || newIndex < new.count {
            let oldStart = oldIndex, newStart = newIndex
            while removed.contains(oldIndex) { oldIndex += 1 }
            while inserted.contains(newIndex) { newIndex += 1 }
            if oldStart != oldIndex || newStart != newIndex {
                let replacement = new[newStart..<newIndex].joined()
                edits.append(Self(original: old[oldStart..<oldIndex].joined(), replacement: replacement,
                                  offset: offset, userComments: notes))
                offset += replacement.utf16.count
            }
            if newIndex < new.count {
                offset += new[newIndex].utf16.count
                oldIndex += 1
                newIndex += 1
            }
        }
        return edits
    }
}
