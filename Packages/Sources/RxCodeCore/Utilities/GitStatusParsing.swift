import Foundation

/// Pure-function git status porcelain output parser.
/// Extracted for unit testing — no process spawning, no I/O.
public func parseGitStatusPorcelain(_ output: String) -> (modified: Int, added: Int, deleted: Int) {
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    var modified = 0
    var added = 0
    var deleted = 0

    for line in lines {
        guard line.count >= 2 else { continue }
        let index = line.index(line.startIndex, offsetBy: 1)
        let statusChar = line[index]
        switch statusChar {
        case "M": modified += 1
        case "A", "?": added += 1
        case "D": deleted += 1
        default: modified += 1
        }
    }

    return (modified: modified, added: added, deleted: deleted)
}
