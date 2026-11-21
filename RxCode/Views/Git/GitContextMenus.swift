import AppKit
import RxCodeCore
import SwiftUI

struct GitCommitContextMenu: View {
    let commit: GitCommit
    let store: GitWorkflowStore

    private var root: String { store.root }
    private var onCurrentBranch: Bool { store.isOnCurrentBranch(commit) }
    private var isHead: Bool { commit.id == store.snapshot.headCommit }
    private var branchName: String { store.snapshot.currentBranch ?? String(localized: "HEAD") }

    var body: some View {
        Button("Checkout Commit") {
            store.perform("Checking out commit…") { await GitWorkflow.checkoutDetached(commit.id, at: root) }
        }
        .disabled(isHead)
        Button("Create Branch Here…") {
            store.sheet = .createBranch(startPoint: commit.id, label: commit.shortID)
        }
        Button("Create Tag Here…") { store.sheet = .createTag(commit) }

        Divider()

        Button("Cherry-pick Commit") {
            store.perform("Cherry-picking…") { await GitWorkflow.cherryPick(commit.id, at: root) }
        }
        .disabled(onCurrentBranch)
        Button("Revert Commit") {
            store.perform("Reverting commit…") { await GitWorkflow.revert(commit, at: root) }
        }
        Button("Merge into \(branchName)") {
            store.perform("Merging…") { await GitWorkflow.merge(commit.id, noFastForward: false, at: root) }
        }
        .disabled(onCurrentBranch)
        Button("Rebase \(branchName) onto Here") {
            store.perform("Rebasing…") { await GitWorkflow.rebase(onto: commit.id, at: root) }
        }
        .disabled(onCurrentBranch)

        Divider()

        Button("Reword…") { store.sheet = .reword(commit) }
            .disabled(!onCurrentBranch)
        Button("Interactive Rebase from Here…") { store.beginInteractiveRebase(from: commit) }
            .disabled(!onCurrentBranch)
        Menu("Reset \(branchName) to Here") {
            Button("Soft — keep changes staged") { store.confirmation = .reset(commit, .soft) }
            Button("Mixed — keep changes unstaged") { store.confirmation = .reset(commit, .mixed) }
            Button("Hard — discard all changes") { store.confirmation = .reset(commit, .hard) }
        }
        .disabled(isHead)

        Divider()

        Button("Copy Commit SHA") { copy(commit.id) }
        Button("Copy Commit Message") { copy(commit.fullMessage) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct GitLocalBranchContextMenu: View {
    let branch: GitLocalBranch
    let store: GitWorkflowStore

    private var current: String { store.snapshot.currentBranch ?? String(localized: "HEAD") }

    var body: some View {
        Button("Checkout") {
            store.perform("Switching branch…") { await GitWorkflow.checkout(branch.name, at: store.root) }
        }
        .disabled(branch.isCurrent)
        Button("Create Branch from \(branch.name)…") {
            store.sheet = .createBranch(startPoint: branch.name, label: branch.name)
        }
        Divider()
        Button("Merge \(branch.name) into \(current)") {
            store.perform("Merging…") { await GitWorkflow.merge(branch.name, noFastForward: false, at: store.root) }
        }
        .disabled(branch.isCurrent)
        Button("Rebase \(current) onto \(branch.name)") {
            store.perform("Rebasing…") { await GitWorkflow.rebase(onto: branch.name, at: store.root) }
        }
        .disabled(branch.isCurrent)
        Divider()
        Button(branch.upstream == nil ? "Publish Branch…" : "Push…") {
            store.sheet = .push(.branch(branch))
        }
        Button("Rename…") { store.sheet = .renameBranch(branch.name) }
        Button("Delete…", role: .destructive) { store.confirmation = .deleteBranch(branch.name) }
            .disabled(branch.isCurrent)
    }
}

struct GitRemoteBranchContextMenu: View {
    let branch: GitRemoteBranch
    let store: GitWorkflowStore

    private var current: String { store.snapshot.currentBranch ?? String(localized: "HEAD") }

    var body: some View {
        Button("Checkout \(branch.name)") {
            store.perform("Switching branch…") {
                await GitWorkflow.checkout(remote: branch, localBranches: store.snapshot.localBranches, at: store.root)
            }
        }
        Button("Create Branch from \(branch.refName)…") {
            store.sheet = .createBranch(startPoint: branch.refName, label: branch.refName)
        }
        Divider()
        Button("Merge \(branch.refName) into \(current)") {
            store.perform("Merging…") { await GitWorkflow.merge(branch.refName, noFastForward: false, at: store.root) }
        }
        Button("Rebase \(current) onto \(branch.refName)") {
            store.perform("Rebasing…") { await GitWorkflow.rebase(onto: branch.refName, at: store.root) }
        }
        Divider()
        Button("Delete from \(branch.remote)…", role: .destructive) { store.confirmation = .deleteRemoteBranch(branch) }
    }
}

struct GitTagContextMenu: View {
    let tag: GitTag
    let store: GitWorkflowStore

    var body: some View {
        Button("Checkout Tag") {
            store.perform("Checking out tag…") { await GitWorkflow.checkoutDetached("refs/tags/\(tag.name)", at: store.root) }
        }
        Button("Push Tag…") {
            store.sheet = .push(.tag(tag))
        }
        .disabled(store.snapshot.remotes.isEmpty)
        Divider()
        Button("Delete…", role: .destructive) { store.confirmation = .deleteTag(tag.name) }
    }
}

struct GitStashContextMenu: View {
    let stash: GitStash
    let store: GitWorkflowStore

    var body: some View {
        Button("Apply") {
            store.perform("Applying stash…") { await GitWorkflow.applyStash(stash, pop: false, at: store.root) }
        }
        Button("Pop") {
            store.perform("Popping stash…") { await GitWorkflow.applyStash(stash, pop: true, at: store.root) }
        }
        Divider()
        Button("Drop…", role: .destructive) { store.confirmation = .dropStash(stash) }
    }
}
