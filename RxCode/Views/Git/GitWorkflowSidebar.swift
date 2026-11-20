import RxCodeCore
import SwiftUI

struct GitWorkflowSidebar: View {
    @Bindable var store: GitWorkflowStore
    @Environment(RepositoryStatus.self) private var repository
    @State private var filter = ""

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
                .tag(GitSidebarItem.localChanges)
                Label("All Commits", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(GitSidebarItem.allCommits)
            }

            Section("Branches") {
                ForEach(store.snapshot.localBranches.filter { matches($0.name) }) { branch in
                    GitBranchRow(branch: branch)
                        .tag(GitSidebarItem.branch(branch.name))
                        .contextMenu { GitLocalBranchContextMenu(branch: branch, store: store) }
                }
            }

            Section {
                ForEach(remoteGroups, id: \.remote) { group in
                    DisclosureGroup {
                        ForEach(group.branches) { branch in
                            Label(branch.name, systemImage: "arrow.triangle.branch")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(GitSidebarItem.remoteBranch(branch.refName))
                                .contextMenu { GitRemoteBranchContextMenu(branch: branch, store: store) }
                        }
                    } label: {
                        Label(group.remote, systemImage: "cloud")
                            .contextMenu {
                                Button("Remove Remote…", role: .destructive) { store.confirmation = .removeRemote(group.remote) }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Remotes")
                    Spacer()
                    Button { store.sheet = .addRemote } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add Remote")
                        .accessibilityLabel("Add Remote")
                }
            }

            let tags = store.snapshot.tags.filter { matches($0.name) }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { tag in
                        Label(tag.name, systemImage: "tag")
                            .lineLimit(1)
                            .tag(GitSidebarItem.tag(tag.name))
                            .contextMenu { GitTagContextMenu(tag: tag, store: store) }
                    }
                }
            }

            if !store.snapshot.stashes.isEmpty {
                Section("Stashes") {
                    ForEach(store.snapshot.stashes) { stash in
                        Label {
                            Text(stash.message).lineLimit(1)
                        } icon: { Image(systemName: "archivebox") }
                        .help(stash.selector)
                        .tag(GitSidebarItem.stash(stash.selector))
                        .contextMenu { GitStashContextMenu(stash: stash, store: store) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter refs")
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
                .foregroundStyle(branch.isCurrent ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        }
        .help(branch.upstream.map { String(localized: "\(branch.name) tracks \($0)") } ?? branch.name)
        .accessibilityLabel(branch.isCurrent ? String(localized: "\(branch.name), current branch") : branch.name)
    }
}
