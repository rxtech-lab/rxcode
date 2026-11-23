import AppKit
import RxCodeCore
import SwiftUI

enum GitGraphPalette {
    static let colors: [Color] = [
        .hex(0x3B82F6), .hex(0xF97316), .hex(0x10B981), .hex(0xA855F7),
        .hex(0xEF4444), .hex(0x14B8A6), .hex(0xEAB308), .hex(0xEC4899),
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

/// Commit list with a lane graph, ref badges, and the history-editing context menu.
struct GitHistoryGraphView: View {
    @Bindable var store: GitWorkflowStore
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 28
    static let laneWidth: CGFloat = 14
    static let maxVisibleLanes = 14

    var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            if store.commits.isEmpty {
                Group {
                    if store.isLoadingHistory {
                        ProgressView("Loading history…").controlSize(.small)
                    } else {
                        ContentUnavailableView("No commits yet", systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text("Commits appear here after the first commit."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var graphColumnWidth: CGFloat {
        CGFloat(min(store.graphWidth, Self.maxVisibleLanes)) * Self.laneWidth + 8
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Commit").frame(maxWidth: .infinity, alignment: .leading)
            Text("Author").frame(width: 130, alignment: .leading)
            Text("SHA").frame(width: 64, alignment: .leading)
            Text("Date").frame(width: 144, alignment: .leading)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(ClaudeTheme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ClaudeTheme.surfacePrimary)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(zip(store.commits, store.rows)), id: \.0.id) { commit, row in
                        GitHistoryRow(
                            commit: commit,
                            row: row,
                            graphWidth: graphColumnWidth,
                            snapshot: store.snapshot,
                            isSelected: store.selectedCommitID == commit.id,
                            isHead: commit.id == store.snapshot.headCommit,
                            onCheckout: store.checkout
                        )
                        .id(commit.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedCommitID = commit.id
                            focused = true
                        }
                        .contextMenu { GitCommitContextMenu(commit: commit, store: store) }
                    }
                    if store.canLoadMore {
                        Button("Load more commits") { Task { await store.loadMore() } }
                            .buttonStyle(.link)
                            .padding(12)
                            .disabled(store.isLoadingHistory)
                    }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
            .onChange(of: store.selectedCommitID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = store.commits.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = store.selectedCommitID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = min(max(current + offset, 0), ids.count - 1)
        store.selectedCommitID = ids[next]
        return .handled
    }
}

private struct GitHistoryRow: View {
    let commit: GitCommit
    let row: GitGraphRow
    let graphWidth: CGFloat
    let snapshot: GitRepositorySnapshot
    let isSelected: Bool
    let isHead: Bool
    let onCheckout: (GitSidebarItem) -> Void

    var body: some View {
        HStack(spacing: 8) {
            GitGraphCell(row: row, isHead: isHead, isMerge: commit.isMerge)
                .frame(width: graphWidth, height: GitHistoryGraphView.rowHeight)
                .clipped()
            HStack(spacing: 5) {
                GitRefBadges(refs: commit.refs, snapshot: snapshot, branchColor: GitGraphPalette.color(row.colorIndex),
                             onCheckout: onCheckout)
                Text(commit.subject)
                    .fontWeight(isHead ? .semibold : .regular)
                    .foregroundStyle(commit.isMerge ? ClaudeTheme.textSecondary : ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(commit.authorName)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(commit.shortID)
                .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(commit.authorDate.formatted(date: .abbreviated, time: .shortened))
                .lineLimit(1)
                .frame(width: 144, alignment: .leading)
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .font(.system(size: ClaudeTheme.size(12)))
        .padding(.horizontal, 10)
        .frame(height: GitHistoryGraphView.rowHeight)
        .background(isSelected ? ClaudeTheme.accent.opacity(0.18) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(commit.subject), \(commit.authorName), \(commit.shortID)")
        .accessibilityValue(commit.refs.map(\.name).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Draws one row of lanes: straight pass-through lines, curves into merges and
/// out to forks, and the commit node.
struct GitGraphCell: View {
    let row: GitGraphRow
    let isHead: Bool
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            let lane = GitHistoryGraphView.laneWidth
            func x(_ column: Int) -> CGFloat { CGFloat(column) * lane + lane / 2 + 4 }
            func y(_ anchor: GitGraphRow.Anchor) -> CGFloat {
                switch anchor {
                case .top: 0
                case .center: size.height / 2
                case .bottom: size.height
                }
            }
            for segment in row.segments {
                var path = Path()
                let start = CGPoint(x: x(segment.fromColumn), y: y(segment.from))
                let end = CGPoint(x: x(segment.toColumn), y: y(segment.to))
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let midY = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
                }
                context.stroke(path, with: .color(GitGraphPalette.color(segment.colorIndex)), lineWidth: 2)
            }
            let center = CGPoint(x: x(row.column), y: size.height / 2)
            let radius: CGFloat = isMerge ? 3.5 : 4.5
            let node = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let color = GitGraphPalette.color(row.colorIndex)
            if isMerge {
                context.fill(node, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(node, with: .color(color), lineWidth: 2)
            } else {
                context.fill(node, with: .color(color))
            }
            if isHead {
                let ring = Path(ellipseIn: CGRect(x: center.x - radius - 2.5, y: center.y - radius - 2.5,
                                                  width: (radius + 2.5) * 2, height: (radius + 2.5) * 2))
                context.stroke(ring, with: .color(color), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Commit graph") {
    let now = Date()
    func commit(_ id: String, _ parents: [String], _ subject: String, refs: [GitRef] = []) -> GitCommit {
        GitCommit(id: id + String(repeating: "0", count: 33), parents: parents.map { $0 + String(repeating: "0", count: 33) },
                  authorName: "Ada Lovelace", authorEmail: "ada@example.com", authorDate: now, subject: subject, refs: refs)
    }
    let commits = [
        commit("1111111", ["2222222", "3333333"], "Merge branch 'feature/graph'", refs: [GitRef(kind: .localBranch, name: "main", isCurrent: true), GitRef(kind: .remoteBranch, name: "origin/main")]),
        commit("3333333", ["4444444"], "Draw lane curves", refs: [GitRef(kind: .localBranch, name: "feature/graph")]),
        commit("5555555", ["6666666"], "Experiment on a side branch", refs: [GitRef(kind: .localBranch, name: "spike")]),
        commit("2222222", ["6666666"], "Fix sidebar refresh"),
        commit("4444444", ["6666666"], "Parse git log records"),
        commit("6666666", ["7777777"], "Add Git window", refs: [GitRef(kind: .tag, name: "v1.0")]),
        commit("7777777", [], "Initial commit"),
    ]
    let rows = GitGraphLayout.layout(commits)
    let width = CGFloat(rows.map(\.width).max() ?? 1) * GitHistoryGraphView.laneWidth + 8
    return VStack(spacing: 0) {
        ForEach(Array(zip(commits, rows)), id: \.0.id) { commit, row in
            GitHistoryRow(commit: commit, row: row, graphWidth: width, snapshot: GitRepositorySnapshot(),
                          isSelected: commit.subject == "Draw lane curves",
                          isHead: commit.id.hasPrefix("1111111"), onCheckout: { _ in })
        }
    }
    .frame(width: 820)
    .padding(.vertical, 8)
}
#endif
