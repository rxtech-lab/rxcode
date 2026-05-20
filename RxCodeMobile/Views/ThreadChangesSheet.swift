import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Sheet listing the changes for a thread, reached from the thread's ⋯ menu.
/// A segmented control switches between every file edited across the thread
/// session ("This Turn") and the project's uncommitted git changes
/// ("Uncommitted"). Tapping a file pushes a full diff page.
struct ThreadChangesSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    private enum Tab: Hashable {
        case thisTurn
        case uncommitted
    }

    @State private var tab: Tab = .thisTurn

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Changes", selection: $tab) {
                    Text("This Turn").tag(Tab.thisTurn)
                    Text("Uncommitted").tag(Tab.uncommitted)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                content
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.isLoadingThreadChanges)
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        await state.requestThreadChanges(sessionID: sessionID)
    }

    /// The current result, but only when it belongs to this thread — a stale
    /// result for a previously-opened thread is treated as "not yet loaded".
    private var result: ThreadChangesResultPayload? {
        guard let changes = state.threadChanges, changes.sessionID == sessionID else { return nil }
        return changes
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let result {
            switch tab {
            case .thisTurn:
                // Thread edits are valid even when the git lookup failed, so
                // they are never gated behind `ok`.
                turnList(result.turnEdits)
            case .uncommitted:
                if result.ok {
                    uncommittedList(result.uncommitted)
                } else {
                    errorState(result.errorMessage ?? "Could not load changes.")
                }
            }
        } else if state.isPaired {
            loadingState
        } else {
            errorState("Not connected to your Mac.")
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading changes…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await load() } }
        }
    }

    private func emptyState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Changes", systemImage: "checkmark.circle")
        } description: {
            Text(message)
        }
    }

    // MARK: - This Turn

    @ViewBuilder
    private func turnList(_ edits: [SyncFileEdit]) -> some View {
        if edits.isEmpty {
            emptyState("No files have been edited in this thread yet.")
        } else {
            List(edits) { edit in
                NavigationLink {
                    ThreadChangeDetailView(
                        title: edit.name,
                        subtitle: edit.path,
                        diff: .hunks(edit.hunks.map {
                            PreviewFile.EditHunk(oldString: $0.oldString, newString: $0.newString)
                        }),
                        truncated: false
                    )
                } label: {
                    fileRow(
                        name: edit.name,
                        path: edit.path,
                        badge: edit.containsWrite ? "W" : "M",
                        badgeColor: edit.containsWrite ? .blue : .orange,
                        stat: hunkStat(edit.hunks)
                    )
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    // MARK: - Uncommitted

    @ViewBuilder
    private func uncommittedList(_ changes: [SyncGitChange]) -> some View {
        if changes.isEmpty {
            emptyState("No uncommitted changes.")
        } else {
            List {
                gitSection("Staged", changes.filter { $0.kind == .staged })
                gitSection("Unstaged", changes.filter { $0.kind == .unstaged })
                gitSection("Untracked", changes.filter { $0.kind == .untracked })
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private func gitSection(_ title: String, _ changes: [SyncGitChange]) -> some View {
        if !changes.isEmpty {
            Section(title) {
                ForEach(changes) { change in
                    NavigationLink {
                        ThreadChangeDetailView(
                            title: fileName(change.displayPath),
                            subtitle: change.displayPath,
                            diff: .unified(change.unifiedDiff),
                            truncated: change.truncated
                        )
                    } label: {
                        fileRow(
                            name: fileName(change.displayPath),
                            path: change.displayPath,
                            badge: change.statusChar,
                            badgeColor: gitStatusColor(change),
                            stat: unifiedStat(change.unifiedDiff)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func fileRow(
        name: String,
        path: String,
        badge: String,
        badgeColor: Color,
        stat: (added: Int, removed: Int)
    ) -> some View {
        HStack(spacing: 10) {
            Text(badge)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(badgeColor, in: RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if stat.added > 0 {
                    Text("+\(stat.added)").foregroundStyle(.green)
                }
                if stat.removed > 0 {
                    Text("−\(stat.removed)").foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func gitStatusColor(_ change: SyncGitChange) -> Color {
        if change.kind == .untracked { return .blue }
        switch change.statusChar {
        case "A": return .green
        case "D": return .red
        case "R", "C": return .purple
        default: return .orange
        }
    }

    private func hunkStat(_ hunks: [SyncEditHunk]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for hunk in hunks {
            if !hunk.oldString.isEmpty {
                removed += hunk.oldString.components(separatedBy: "\n").count
            }
            if !hunk.newString.isEmpty {
                added += hunk.newString.components(separatedBy: "\n").count
            }
        }
        return (added, removed)
    }

    private func unifiedStat(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }
        return (added, removed)
    }
}

/// Full-screen diff page for one changed file, pushed from `ThreadChangesSheet`.
struct ThreadChangeDetailView: View {
    enum Diff {
        case unified(String)
        case hunks([PreviewFile.EditHunk])
    }

    let title: String
    let subtitle: String
    let diff: Diff
    let truncated: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)

                if truncated {
                    Label(
                        "Diff truncated — open this file on your Mac for the full diff.",
                        systemImage: "scissors"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }

                diffBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var diffBody: some View {
        switch diff {
        case .unified(let text):
            if text.isEmpty {
                emptyDiff
            } else {
                ChangeDiffView(unifiedDiff: text)
            }
        case .hunks(let hunks):
            if hunks.isEmpty {
                emptyDiff
            } else {
                ChangeDiffView(hunks: hunks)
            }
        }
    }

    private var emptyDiff: some View {
        Text("No diff content available.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
    }
}
