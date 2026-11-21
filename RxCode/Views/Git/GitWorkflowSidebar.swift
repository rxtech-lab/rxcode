import RxCodeCore
import SwiftUI

struct GitWorkflowSidebar: View {
    private static let tagPageSize = 10

    @Bindable var store: GitWorkflowStore
    @Environment(RepositoryStatus.self) private var repository
    @State private var filter = ""
    @State private var branchesExpanded = true
    @State private var remotesExpanded = false
    @State private var tagsExpanded = false
    @State private var stashesExpanded = true
    @State private var visibleTagCount = Self.tagPageSize

    private var changeCount: Int {
        guard case .ready(let tree) = repository.state else { return 0 }
        return Set(tree.changes.unstaged.map(\.displayPath) + tree.changes.staged.map(\.displayPath)).count
    }

    private func matches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedCaseInsensitiveContains(filter)
    }

    private var remoteGroups: [(remote: String, branches: [GitRemoteBranch])] {
        let grouped = Dictionary(grouping: store.snapshot.remoteBranches.filter { matches($0.refName) }, by: \.remote)
        return store.snapshot.remotes.map { ($0, grouped[$0] ?? []) }
    }

    private var filteredTags: [GitTag] {
        filter.isEmpty ? store.snapshot.tags : store.snapshot.tags.filter { matches($0.name) }
    }

    var body: some View {
        List(selection: Binding(get: { store.selection }, set: { if let value = $0 { store.selection = value } })) {
            Section("Workspace") {
                Label {
                    HStack {
                        Text("Local Changes")
                        Spacer()
                        if changeCount > 0 {
                            Text("\(changeCount)").monospacedDigit().foregroundStyle(ClaudeTheme.textSecondary)
                        }
                    }
                } icon: { Image(systemName: "pencil.and.list.clipboard") }
                .themedListRow(GitSidebarItem.localChanges, selection: store.selection)
                Label("All Commits", systemImage: "point.3.connected.trianglepath.dotted")
                    .themedListRow(GitSidebarItem.allCommits, selection: store.selection)
            }

            TextField("Filter refs", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Section("Branches", isExpanded: $branchesExpanded) {
                ForEach(store.snapshot.localBranches.filter { matches($0.name) }) { branch in
                    GitBranchRow(branch: branch)
                        .themedListRow(GitSidebarItem.branch(branch.name), selection: store.selection)
                        .contextMenu { GitLocalBranchContextMenu(branch: branch, store: store) }
                }
            }

            Section {
                GitRefGroupHeader("Remotes", isExpanded: $remotesExpanded) {
                    Button { store.sheet = .addRemote } label: { Image(systemName: "plus") }
                        .help("Add Remote")
                        .accessibilityLabel("Add Remote")
                }
                if remotesExpanded {
                    ForEach(remoteGroups, id: \.remote) { group in
                        DisclosureGroup {
                            ForEach(group.branches) { branch in
                                Label(branch.name, systemImage: "arrow.triangle.branch")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .themedListRow(GitSidebarItem.remoteBranch(branch.refName), selection: store.selection)
                                    .contextMenu { GitRemoteBranchContextMenu(branch: branch, store: store) }
                            }
                        } label: {
                            Label(group.remote, systemImage: "cloud")
                                .listItemTint(.fixed(ClaudeTheme.accent))
                                .contextMenu {
                                    Button("Remove Remote…", role: .destructive) { store.confirmation = .removeRemote(group.remote) }
                                }
                        }
                    }
                }
            }

            if !store.snapshot.tags.isEmpty {
                Section {
                    GitRefGroupHeader("Tags", isExpanded: $tagsExpanded) {
                        Button { store.sheet = .searchTags } label: { Image(systemName: "magnifyingglass") }
                            .help("Search Tags")
                            .accessibilityLabel("Search Tags")
                    }
                    if tagsExpanded {
                        let tags = filteredTags
                        ForEach(tags.prefix(visibleTagCount)) { tag in
                            GitTagRow(tag: tag)
                                .padding(.leading, 12)
                                .themedListRow(GitSidebarItem.tag(tag.name), selection: store.selection)
                                .contextMenu { GitTagContextMenu(tag: tag, store: store) }
                        }
                        if tags.count > visibleTagCount {
                            let nextCount = min(Self.tagPageSize, tags.count - visibleTagCount)
                            Button("Show \(nextCount) More") { visibleTagCount += nextCount }
                                .buttonStyle(.link)
                                .padding(.leading, 12)
                        }
                    }
                }
            }

            if !store.snapshot.stashes.isEmpty {
                Section("Stashes", isExpanded: $stashesExpanded) {
                    ForEach(store.snapshot.stashes) { stash in
                        Label {
                            Text(stash.message).lineLimit(1)
                        } icon: { Image(systemName: "archivebox") }
                        .help(stash.selector)
                        .themedListRow(GitSidebarItem.stash(stash.selector), selection: store.selection)
                        .contextMenu { GitStashContextMenu(stash: stash, store: store) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: filter) { visibleTagCount = Self.tagPageSize }
        .onChange(of: tagsExpanded) {
            if !tagsExpanded { visibleTagCount = Self.tagPageSize }
        }
    }
}

private struct GitRefGroupHeader<Action: View>: View {
    let title: LocalizedStringResource
    @Binding var isExpanded: Bool
    @ViewBuilder let action: () -> Action

    init(_ title: LocalizedStringResource, isExpanded: Binding<Bool>, @ViewBuilder action: @escaping () -> Action) {
        self.title = title
        _isExpanded = isExpanded
        self.action = action
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    Text(title)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            action()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}

struct GitTagRow: View {
    let tag: GitTag

    var body: some View {
        Label(tag.name, systemImage: "tag")
            .lineLimit(1)
            .truncationMode(.middle)
            .help(tag.name)
    }
}

private struct GitBranchRow: View {
    let branch: GitLocalBranch

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(branch.name)
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if branch.ahead > 0 {
                    Text("↑\(branch.ahead)").monospacedDigit()
                }
                if branch.behind > 0 {
                    Text("↓\(branch.behind)").monospacedDigit()
                }
            }
            .font(.system(size: ClaudeTheme.size(12)))
        } icon: {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isCurrent ? ClaudeTheme.foreground(ClaudeTheme.accent) : ClaudeTheme.textSecondary)
        }
        .help(branch.upstream.map { String(localized: "\(branch.name) tracks \($0)") } ?? branch.name)
        .accessibilityLabel(branch.isCurrent ? String(localized: "\(branch.name), current branch") : branch.name)
    }
}
