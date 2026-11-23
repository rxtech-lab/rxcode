import RxCodeCore
import SwiftUI

/// Pairs the local and remote decorations on a commit without losing their checkout targets.
struct GitRefBadges: View {
    let refs: [GitRef]
    let snapshot: GitRepositorySnapshot
    var branchColor = ClaudeTheme.accent
    let onCheckout: (GitSidebarItem) -> Void

    private struct Entry: Identifiable {
        let ref: GitRef
        let title: String
        let remotes: [GitRef]
        var id: GitRef { ref }
    }

    private func shortName(for remote: GitRef) -> String {
        // The snapshot also resolves remote names containing slashes.
        snapshot.remoteBranches.first { $0.refName == remote.name }?.name
            ?? String(remote.name.split(separator: "/", maxSplits: 1).last ?? "")
    }

    private var entries: [Entry] {
        guard !refs.isEmpty else { return [] }
        let remoteRefs = refs.filter { $0.kind == .remoteBranch }
        var localRemotes: [GitRef: [GitRef]] = [:]
        var paired = Set<GitRef>()
        for ref in refs where ref.kind == .localBranch {
            let local = snapshot.localBranches.first { $0.name == ref.name }
            let upstream = local?.upstreamRemote == "." ? nil : local?.upstream
            let matches = remoteRefs.filter { shortName(for: $0) == ref.name || $0.name == upstream }
            paired.formUnion(matches)
            if matches.isEmpty, let local {
                // A branch can have a remote even when their tips have diverged.
                localRemotes[ref] = snapshot.remoteBranches(for: local).map {
                    GitRef(kind: .remoteBranch, name: local.upstream ?? $0.refName)
                }
            } else {
                localRemotes[ref] = matches
            }
        }
        let standalone = Dictionary(grouping: remoteRefs.filter { !paired.contains($0) }, by: shortName)
        return refs.compactMap { ref in
            guard ref.kind == .remoteBranch else {
                return Entry(ref: ref, title: ref.name, remotes: localRemotes[ref] ?? [])
            }
            let title = shortName(for: ref)
            guard let remotes = standalone[title], remotes.first == ref else { return nil }
            return Entry(ref: ref, title: title, remotes: remotes)
        }
    }

    var body: some View {
        ForEach(entries) { entry in
            HStack(spacing: 2) {
                if entry.ref.kind == .localBranch, let remote = entry.remotes.first {
                    GitRefBadge(ref: remote, title: nil, remoteChoices: entry.remotes,
                                branchColor: branchColor, onCheckout: onCheckout)
                }
                GitRefBadge(ref: entry.ref, title: entry.title,
                            remoteChoices: entry.ref.kind == .remoteBranch ? entry.remotes : [],
                            showsLocalSymbol: entry.remotes.isEmpty,
                            branchColor: branchColor, onCheckout: onCheckout)
            }
        }
    }
}

private struct GitRefBadge: View {
    let ref: GitRef
    let title: String?
    var remoteChoices: [GitRef] = []
    var showsLocalSymbol = false
    let branchColor: Color
    let onCheckout: (GitSidebarItem) -> Void

    private var branch: GitSidebarItem? {
        switch ref.kind {
        case .localBranch where !ref.isCurrent: .branch(ref.name)
        case .remoteBranch: .remoteBranch(ref.name)
        default: nil
        }
    }

    private var style: (symbol: String?, color: Color) {
        switch ref.kind {
        case .head: ("location.fill", ClaudeTheme.statusWarning)
        case .localBranch: (showsLocalSymbol ? "arrow.triangle.branch" : nil, branchColor)
        case .remoteBranch: (nil, branchColor)
        case .tag: ("tag", ClaudeTheme.statusSuccess)
        case .other: ("bookmark", ClaudeTheme.textSecondary)
        }
    }

    var body: some View {
        if remoteChoices.count > 1 {
            Menu {
                ForEach(remoteChoices, id: \.self) { remote in
                    Button("Checkout \(remote.name)") { onCheckout(.remoteBranch(remote.name)) }
                }
            } label: { badge }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(remoteChoices.map(\.name).joined(separator: ", "))
            .accessibilityLabel("Remote branches")
            .accessibilityValue(remoteChoices.map(\.name).joined(separator: ", "))
        } else if let branch {
            badge
                .simultaneousGesture(TapGesture(count: 2).onEnded { onCheckout(branch) })
                .help("Double-click to check out \(ref.name)")
                .accessibilityAction(named: "Checkout") { onCheckout(branch) }
        } else {
            badge
                .help(ref.isCurrent ? String(localized: "\(ref.name) (current branch)") : ref.name)
        }
    }

    private var badge: some View {
        HStack(spacing: 2) {
            if ref.kind == .remoteBranch {
                chip(padding: 4) {
                    Image(.gitHubMark)
                        .resizable()
                        .scaledToFit()
                        .frame(width: ClaudeTheme.size(12), height: ClaudeTheme.size(12))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
            }
            if let title {
                chip(padding: 5) {
                    if let symbol = style.symbol {
                        Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
        }
        .accessibilityLabel(ref.name)
    }

    private func chip(padding: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        let isBranch = ref.kind == .localBranch || ref.kind == .remoteBranch
        let background = ClaudeTheme.surfacePrimary.mix(with: style.color, by: ref.isCurrent ? 0.22 : 0.12)
        let shape = RoundedRectangle(cornerRadius: 4)
        return content()
            .font(.system(size: ClaudeTheme.size(isBranch ? 11 : 10), weight: ref.isCurrent ? .bold : .medium))
            .lineLimit(1)
            .padding(.horizontal, padding)
            .frame(height: ClaudeTheme.size(17))
            .foregroundStyle(isBranch ? ClaudeTheme.textPrimary : ClaudeTheme.semanticForeground(style.color, on: background))
            .background(background, in: shape)
            .overlay {
                if isBranch { shape.strokeBorder(style.color, lineWidth: 1) }
            }
            .fixedSize()
    }
}
