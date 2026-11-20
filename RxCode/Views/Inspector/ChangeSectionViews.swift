import RxCodeCore
import SwiftUI

struct ChangeFileRow: View {
    let file: GitChangeFile

    private var description: (title: LocalizedStringResource, symbol: String, color: Color) {
        switch file.statusChar {
        case "?": ("Untracked", "doc.badge.plus", ClaudeTheme.statusSuccess)
        case "A": ("Added", "plus.circle", ClaudeTheme.statusSuccess)
        case "D": ("Deleted", "minus.circle", ClaudeTheme.statusError)
        case "U": ("Conflict", "exclamationmark.triangle", ClaudeTheme.statusError)
        case "R": ("Renamed", "arrow.right.circle", ClaudeTheme.accent)
        case "C": ("Copied", "doc.on.doc", ClaudeTheme.accent)
        default: ("Modified", "pencil", ClaudeTheme.statusWarning)
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: description.symbol)
                .foregroundStyle(description.color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                if !file.parentDirectory.isEmpty {
                    Text(file.parentDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: String(file.statusChar))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(description.color)
                .help(Text(description.title))
                .accessibilityLabel(Text(description.title))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-file-\(file.displayPath)")
    }
}
