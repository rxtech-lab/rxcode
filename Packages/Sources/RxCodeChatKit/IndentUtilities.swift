import Foundation

/// Strips the leading whitespace prefix that's common to every non-blank line
/// across both arrays. Shared between FileDiffView (macOS) and ToolResultView
/// (cross-platform) so both stay consistent.
nonisolated func stripCommonIndent(old: [String], new: [String]) -> (old: [String], new: [String]) {
    let combined = old + new
    let commonIndent = combined
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
        .min() ?? 0
    guard commonIndent > 0 else { return (old, new) }
    func strip(_ line: String) -> String {
        line.count >= commonIndent ? String(line.dropFirst(commonIndent)) : line
    }
    return (old.map(strip), new.map(strip))
}
