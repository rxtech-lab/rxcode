import RxCodeCore
import SwiftUI

struct GitWorkingFileRow: View {
    let file: GitChangeFile
    @State private var untrackedChanges: GitLineChanges?

    var body: some View {
        GitChangedFileRow(
            name: file.name, path: file.displayPath, originalPath: file.originalPath,
            status: file.statusChar, lineChanges: file.lineChanges ?? untrackedChanges
        )
        .accessibilityIdentifier("git-file-\(file.displayPath)")
        .task(id: file.untrackedModificationDate) {
            guard file.untrackedModificationDate != nil else { untrackedChanges = nil; return }
            let directory = (file.path as NSString).deletingLastPathComponent
            let changes = await GitRepositoryLoader.untrackedLineChanges(for: file.path, at: directory)
            guard !Task.isCancelled else { return }
            untrackedChanges = changes
        }
    }
}

struct GitCommitFileRow: View {
    let file: GitCommitFile

    var body: some View {
        GitChangedFileRow(
            name: file.name, path: file.path, originalPath: file.originalPath,
            status: file.status, lineChanges: file.lineChanges
        )
        .accessibilityIdentifier("git-commit-file-\(file.path)")
    }
}

private struct GitChangedFileRow: View {
    let name: String
    let path: String
    let originalPath: String?
    let status: Character
    let lineChanges: GitLineChanges?

    private var badge: (text: String, title: LocalizedStringResource, color: Color) {
        switch status {
        case "?": ("+", "Untracked", ClaudeTheme.statusSuccess)
        case "A": ("+", "Added", ClaudeTheme.statusSuccess)
        case "D": ("−", "Deleted", ClaudeTheme.statusError)
        case "U": ("!", "Conflict", ClaudeTheme.statusError)
        case "R": ("R", "Renamed", ClaudeTheme.accent)
        case "C": ("C", "Copied", ClaudeTheme.accent)
        default: (String(status), "Modified", ClaudeTheme.statusWarning)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: badge.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ClaudeTheme.foreground(on: badge.color))
                .frame(width: 14, height: 14)
                .background(badge.color, in: .rect(cornerRadius: 3))
                .accessibilityLabel(Text(badge.title))
            GitFileIcon(name: name)
            Text(verbatim: name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                switch lineChanges {
                case .text(let added, let deleted):
                    GitLineCountText(text: "+\(added)", color: ClaudeTheme.statusSuccess)
                        .accessibilityLabel("\(added) added lines")
                    GitLineCountText(text: "−\(deleted)", color: ClaudeTheme.statusError)
                        .accessibilityLabel("\(deleted) deleted lines")
                case .binary:
                    Text("Binary")
                case nil:
                    Text("—")
                        .accessibilityLabel("Line counts unavailable")
                }
            }
            .foregroundStyle(.secondary)
            .font(.callout.weight(.semibold).monospacedDigit())
            .fixedSize()
        }
        .help(originalPath.map { "\($0) → \(path)" } ?? path)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Reads the selection fill in its own body so the count re-inks when a row gains or loses emphasis.
private struct GitLineCountText: View {
    let text: String
    let color: Color
    @Environment(\.themeSelectionBackground) private var selection

    var body: some View {
        Text(verbatim: text).foregroundStyle(ClaudeTheme.semanticForeground(color, on: selection))
    }
}
