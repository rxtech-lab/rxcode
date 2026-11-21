import RxCodeCore
import SwiftUI

struct GitPushSheet: View {
    let store: GitWorkflowStore
    @Environment(\.dismiss) private var dismiss
    @State private var branchName: String
    @State private var selectedRemote: String?
    @State private var selectedRef: String?
    @State private var createTracking: Bool
    @State private var pushAllTags = false
    @State private var force = false
    @State private var confirmingForce = false
    @State private var addingRemote = false

    init(store: GitWorkflowStore, initialBranch: GitLocalBranch) {
        self.store = store
        _branchName = State(initialValue: initialBranch.name)
        _createTracking = State(initialValue: !store.snapshot.remotes.contains(initialBranch.upstreamRemote ?? ""))
    }

    var body: some View {
        let branch = store.snapshot.localBranches.first { $0.name == branchName }
        let choices = branch.map(store.snapshot.pushDestinations(for:)) ?? []
        let trackingRemote = branch?.upstreamRemote.flatMap { store.snapshot.remotes.contains($0) ? $0 : nil }
        let remote = selectedRemote ?? trackingRemote ?? store.defaultRemote
        let ref = selectedRef ?? remote.flatMap { branch?.pushDestination(on: $0) }
        let destination = choices.first { $0.remote == remote && $0.ref == ref }

        GitSheetOperation(store: store, progressTitle: force ? "Force pushing…" : "Pushing…", action: {
            guard let branch, let destination else { return String(localized: "Select a remote before pushing.") }
            return await GitWorkflow.push(
                branch: branch, remote: destination.remote, force: force, pushAllTags: pushAllTags,
                destinationRef: destination.ref, setUpstream: createTracking, at: store.root
            )
        }) { submit in
            HStack(alignment: .top, spacing: 24) {
                Image(.gitPushIcon)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Push").font(.system(size: 14, weight: .bold))
                    Text("Push your local changes to remote repository")
                        .font(.system(size: 12))
                        .padding(.top, 2)

                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("Branch:").gridColumnAlignment(.trailing)
                            Picker("Branch", selection: $branchName) {
                                ForEach(store.snapshot.localBranches) { branch in
                                    Label(branch.name, systemImage: "arrow.triangle.branch").tag(branch.name)
                                }
                            }
                            .labelsHidden()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("git-push-branch")
                        }
                        GridRow {
                            Text("To:")
                            if store.snapshot.remotes.isEmpty {
                                Button("Create Remote…") { addingRemote = true }
                            } else {
                                Picker("To", selection: Binding<GitPushDestination?>(
                                    get: { destination },
                                    set: { choice in
                                        guard let choice else { return }
                                        selectedRemote = choice.remote
                                        selectedRef = choice.ref
                                        force = false
                                    }
                                )) {
                                    if destination == nil { Text("Select a remote").tag(nil as GitPushDestination?) }
                                    ForEach(choices, id: \.self) { choice in
                                        Label {
                                            if choice.isNew { Text("new (\(choice.displayName))") }
                                            else { Text(verbatim: choice.displayName) }
                                        } icon: { Image(systemName: "arrow.triangle.branch") }
                                        .tag(Optional(choice))
                                    }
                                }
                                .labelsHidden()
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("git-push-destination")
                            }
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("Create tracking reference", isOn: $createTracking)
                                Toggle("Push all tags", isOn: $pushAllTags)
                                Toggle("Force push", isOn: $force)
                                    .help("Force push with lease")
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .pickerStyle(.menu)
                    .menuOrder(.fixed)
                    .padding(.top, 20)

                    HStack(spacing: 8) {
                        if branch != nil, trackingRemote == nil, !store.snapshot.remotes.isEmpty {
                            Button("Create Remote…") { addingRemote = true }
                                .buttonStyle(.link)
                        }
                        Spacer()
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button("Push") { if force { confirmingForce = true } else { submit() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(destination == nil || branch == nil)
                    }
                    .padding(.top, 8)
                    .confirmationDialog(
                        "Force push to “\(destination?.displayName ?? "")”?",
                        isPresented: $confirmingForce, titleVisibility: .visible
                    ) {
                        Button("Force Push", role: .destructive, action: submit)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Git checks the remote branch against your local remote-tracking ref before rewriting it.")
                    }
                }
            }
            .padding(20)
            .frame(width: 500, alignment: .topLeading)
            .frame(minHeight: 250, maxHeight: .infinity, alignment: .top)
        }
        .presentationSizing(.fitted)
        .onChange(of: branchName) {
            selectedRemote = nil
            selectedRef = nil
            createTracking = trackingRemote == nil
            force = false
        }
        .sheet(isPresented: $addingRemote) {
            GitAddRemoteSheet(store: store) { name in
                selectedRemote = name
                selectedRef = nil
                force = false
            }
        }
    }
}
