import AppKit
import SwiftUI
import RxCodeCore

// MARK: - ChangeSection

struct ChangeSection: View {
    let title: String
    let actionTitle: String
    let files: [GitChangeFile]
    @Binding var selection: Set<String>
    let emptyMessage: String
    let isBusy: Bool
    let onAction: () async -> Void
    let onFocus: () -> Void
    let onEmptyTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if files.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                ChangeFileRow(
                                    file: file,
                                    isSelected: selection.contains(file.displayPath),
                                    onPrimarySelect: {
                                        onFocus()
                                        selectOnly(file)
                                    },
                                    onSecondarySelect: { isCommandPressed in
                                        onFocus()
                                        if isCommandPressed {
                                            toggle(file)
                                        } else {
                                            selectOnly(file)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the empty area inside a section focuses it and clears
            // all selections (both unstaged and staged). Taps on rows are
            // intercepted by the row's own gesture, so this only fires on
            // the background.
            onFocus()
            onEmptyTap()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text("\(files.count)")
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(ClaudeTheme.surfaceSecondary, in: Capsule())
            Spacer()
            Button {
                Task { await onAction() }
            } label: {
                Text(LocalizedStringKey(actionTitle))
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty || isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.4))
    }

    private func toggle(_ file: GitChangeFile) {
        if selection.contains(file.displayPath) {
            selection.remove(file.displayPath)
        } else {
            selection.insert(file.displayPath)
        }
    }

    private func selectOnly(_ file: GitChangeFile) {
        selection = [file.displayPath]
    }
}

// MARK: - ChangeFileRow

struct ChangeFileRow: View {
    let file: GitChangeFile
    let isSelected: Bool
    let onPrimarySelect: () -> Void
    let onSecondarySelect: (_ isCommandPressed: Bool) -> Void

    @Environment(WindowState.self) private var windowState
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.parentDirectory.isEmpty {
                    Text(file.parentDirectory)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent.opacity(0.8) : ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            Text(badgeLabel)
                .font(.system(size: ClaudeTheme.size(9), weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : iconColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    (isSelected ? ClaudeTheme.textOnAccent.opacity(0.2) : iconColor.opacity(0.15)),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture { onPrimarySelect() }
        .overlay {
            ChangeFileRightClickOverlay(
                onRightClick: onSecondarySelect,
                onShowDiff: openDiff
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onHover { isHovering = $0 }
        .help("Click to select · Command-right-click to add or remove · Right-click for Show Diff")
    }

    private func openDiff() {
        windowState.diffFile = PreviewFile(
            path: file.path,
            name: file.name,
            gitDiffMode: file.diffMode
        )
    }

    private var rowFill: Color {
        if isSelected { return ClaudeTheme.accent }
        if isHovering { return ClaudeTheme.surfaceSecondary }
        return .clear
    }

    private var iconName: String {
        if file.isUntracked { return "doc.badge.plus" }
        switch file.statusChar {
        case "A": return "plus.circle"
        case "D": return "minus.circle"
        case "R": return "arrow.right.circle"
        case "C": return "doc.on.doc"
        case "U": return "exclamationmark.triangle"
        default:  return "pencil"
        }
    }

    private var iconColor: Color {
        if file.isUntracked { return ClaudeTheme.statusSuccess }
        switch file.statusChar {
        case "A": return ClaudeTheme.statusSuccess
        case "D": return ClaudeTheme.statusError
        case "U": return ClaudeTheme.statusError
        default:  return ClaudeTheme.statusWarning
        }
    }

    private var badgeLabel: String {
        if file.isUntracked { return "?" }
        return String(file.statusChar)
    }
}

struct ChangeFileRightClickOverlay: NSViewRepresentable {
    let onRightClick: (_ isCommandPressed: Bool) -> Void
    let onShowDiff: () -> Void

    func makeNSView(context: Context) -> RightClickSelectionView {
        let view = RightClickSelectionView()
        view.onRightClick = onRightClick
        view.onShowDiff = onShowDiff
        return view
    }

    func updateNSView(_ nsView: RightClickSelectionView, context: Context) {
        nsView.onRightClick = onRightClick
        nsView.onShowDiff = onShowDiff
    }
}

final class RightClickSelectionView: NSView {
    var onRightClick: ((_ isCommandPressed: Bool) -> Void)?
    var onShowDiff: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent,
              event.type == .rightMouseDown else {
            return nil
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        onRightClick?(modifiers.contains(.command))
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        let showDiffItem = NSMenuItem(title: "Show Diff", action: #selector(showDiff), keyEquivalent: "")
        showDiffItem.target = self
        menu.addItem(showDiffItem)
        menu.popUp(positioning: showDiffItem, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func showDiff() {
        onShowDiff?()
    }
}

// MARK: - Loading

struct GitChangeFile: Identifiable, Hashable {
    let id = UUID()
    let path: String        // absolute path
    let displayPath: String // path relative to repo
    let statusChar: Character
    let isUntracked: Bool
    let diffMode: PreviewFile.GitDiffMode

    var name: String {
        (displayPath as NSString).lastPathComponent
    }

    var parentDirectory: String {
        (displayPath as NSString).deletingLastPathComponent
    }
}

struct GitChangesSnapshot {
    let unstaged: [GitChangeFile]
    let staged: [GitChangeFile]
}

func loadAllChangedFiles(at projectPath: String) async -> GitChangesSnapshot {
    guard let raw = await GitHelper.run(["status", "--porcelain=v1", "-z"], at: projectPath) else {
        return GitChangesSnapshot(unstaged: [], staged: [])
    }
    return parsePorcelainZ(raw, projectPath: projectPath)
}

/// Parses `git status --porcelain=v1 -z` output into both unstaged and staged
/// file lists. Entries are NUL-terminated; renames have an extra NUL-terminated
/// "old path" record.
func parsePorcelainZ(_ raw: String, projectPath: String) -> GitChangesSnapshot {
    var unstaged: [GitChangeFile] = []
    var staged: [GitChangeFile] = []
    let tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var i = 0
    while i < tokens.count {
        let entry = tokens[i]
        i += 1
        guard entry.count >= 3 else { continue }
        let chars = Array(entry)
        let indexChar = chars[0]
        let worktreeChar = chars[1]
        let displayPath = String(entry.dropFirst(3))

        let isUntracked = (indexChar == "?" && worktreeChar == "?")
        let isRename = indexChar == "R" || worktreeChar == "R"
        if isRename, i < tokens.count {
            i += 1
        }

        let absolute = (projectPath as NSString).appendingPathComponent(displayPath)

        // Unstaged includes untracked files and any worktree-side change.
        if isUntracked || (worktreeChar != " " && worktreeChar != "?") {
            let statusChar: Character = isUntracked ? "?" : worktreeChar
            let diffMode: PreviewFile.GitDiffMode = isUntracked ? .untracked : .unstaged
            unstaged.append(GitChangeFile(
                path: absolute,
                displayPath: displayPath,
                statusChar: statusChar,
                isUntracked: isUntracked,
                diffMode: diffMode
            ))
        }

        // Staged: anything with an index-side change other than '?'.
        if !isUntracked, indexChar != " " {
            staged.append(GitChangeFile(
                path: absolute,
                displayPath: displayPath,
                statusChar: indexChar,
                isUntracked: false,
                diffMode: .staged
            ))
        }
    }
    let sort: ([GitChangeFile]) -> [GitChangeFile] = { files in
        files.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }
    return GitChangesSnapshot(unstaged: sort(unstaged), staged: sort(staged))
}
