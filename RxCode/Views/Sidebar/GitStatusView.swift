import RxCodeCore
import SwiftUI

/// Branch management for the checkout selected in the workspace.
struct GitStatusView: View {
    let tree: GitWorkingTree
    @Environment(RepositoryStatus.self) private var repository
    @State private var branches = GitBranchList()
    @State private var filter = ""
    @State private var reloadID = UUID()
    @State private var switching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(ClaudeTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tree.isDetached ? String(localized: "Detached at \(tree.head)") : tree.head)
                        .font(.headline.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tracking = tree.upstream?.upstream {
                        Text(tracking)
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    reloadID = UUID()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh branches")
            }
            .padding(12)
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ClaudeThemeDivider()
            branchList
        }
        .disabled(switching)
        .overlay {
            if switching { ProgressView("Switching branch…").padding().background(.regularMaterial, in: .rect(cornerRadius: 10)) }
        }
        .alert("Couldn’t switch branches", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .task(id: reloadID) {
            await repository.refresh(at: repository.path ?? tree.root)
            let result = await GitRepositoryLoader.branches(at: tree.root)
            guard !Task.isCancelled else { return }
            branches = result
        }
    }

    private var branchList: some View {
        let local = branches.local.filter { matches($0.name) }
        let remote = branches.remote.filter { matches($0.refName) }
        return List {
            if !local.isEmpty {
                Section("Local branches") {
                    ForEach(local) { branch in
                        branchButton(name: branch.name, current: branch.isCurrent) {
                            await GitWorkflow.checkout(branch.name, at: tree.root)
                        }
                    }
                }
            }
            if !remote.isEmpty {
                Section("Remote branches") {
                    ForEach(remote) { branch in
                        branchButton(name: branch.refName, current: false) {
                            await GitWorkflow.checkout(remote: branch, localBranches: branches.local, at: tree.root)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if local.isEmpty && remote.isEmpty {
                ContentUnavailableView(filter.isEmpty ? "No branches yet" : "No matching branches", systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func matches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedCaseInsensitiveContains(filter)
    }

    private func branchButton(name: String, current: Bool, action: @escaping () async -> String?) -> some View {
        Button {
            guard !switching else { return }
            switching = true
            Task {
                error = await action()
                switching = false
                reloadID = UUID()
            }
        } label: {
            HStack {
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ClaudeTheme.accent)
                        .accessibilityLabel("Current branch")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
        .help(current ? String(localized: "Current branch") : String(localized: "Switch to \(name)"))
    }
}
