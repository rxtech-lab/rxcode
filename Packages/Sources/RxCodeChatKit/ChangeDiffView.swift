import SwiftUI
import RxCodeCore
import DiffView

/// Full, non-collapsing diff renderer for a single file. Used by the mobile
/// "View Changes" detail page, which owns a whole screen and therefore renders
/// every diff line. Accepts either a raw unified diff string (git changes) or a
/// set of old/new edit-hunk pairs (thread file edits).
///
/// Rendering is delegated to the shared `DiffView` package so mobile and
/// desktop share the same GitHub-style two-column gutter layout.
public struct ChangeDiffView: View {
    private let lines: [DiffLine]

    /// Renders a raw unified diff, e.g. `git diff` output.
    public init(unifiedDiff: String) {
        self.lines = DiffComputation.parseUnifiedDiff(unifiedDiff)
    }

    /// Renders old/new replacement pairs as a removed-then-added diff.
    public init(hunks: [PreviewFile.EditHunk]) {
        self.lines = DiffComputation.buildEditDiffLines(from: hunks)
    }

    /// Renders the diff between a pre-edit snapshot and a post-edit snapshot.
    /// Preferred when both snapshots are available — gives an exact, thread-
    /// isolated diff with no dependence on hunk anchoring or disk state.
    public init(original: String, modified: String) {
        self.lines = DiffComputation.buildSnapshotDiffLines(original: original, current: modified)
    }

    /// `+/-` counts derived from the same snapshot diff that
    /// `init(original:modified:)` renders, so a sidebar row's badges always
    /// match what the detail page shows.
    public nonisolated static func snapshotStat(original: String, modified: String) -> (added: Int, removed: Int) {
        let lines = DiffComputation.buildSnapshotDiffLines(original: original, current: modified)
        var added = 0
        var removed = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    public var body: some View {
        DiffView(lines: lines, showsBackground: false)
    }
}
