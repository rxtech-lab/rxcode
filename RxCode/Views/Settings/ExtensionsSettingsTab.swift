import ExtensionFoundation
import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct ExtensionsSettingsTab: View {
    @State private var monitor: AppExtensionPoint.Monitor?
    @State private var failure: String?
    @State private var metadata: [String: InstalledExtensionMetadata] = [:]
    @State private var showingBrowser = false
    @State private var selected: InstalledExtensionMetadata?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showingBrowser) {
                NavigationStack {
                    SystemExtensionBrowser()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Manage Extensions")
                        .toolbar { Button("Done") { showingBrowser = false } }
                }
                .frame(minWidth: 540, minHeight: 480)
            }
            .sheet(item: $selected) { item in
                ExtensionDetailSheet(item: item)
            }
            .task {
                do {
                    let available = try await AppExtensionPoint.Monitor(appExtensionPoint: .workspaceContributions)
                    try await available.addAppExtensionPoint(.workspaceServices)
                    monitor = available
                } catch {
                    failure = error.localizedDescription
                }
            }
            .task(id: identityKeys) { await loadMetadata() }
    }

    @ViewBuilder private var content: some View {
        if let failure {
            ContentUnavailableView("Extension discovery failed", systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if monitor == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    PluginAPICard()
                    installedSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Data

    private var identities: [AppExtensionIdentity] {
        (monitor?.identities ?? []).sorted {
            $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
    }

    private var identityKeys: [String] { identities.map { "\($0.bundleIdentifier)|\($0.localizedName)" } }

    private var items: [InstalledExtensionMetadata] {
        identities.map { identity in
            metadata[identity.bundleIdentifier] ?? InstalledExtensionMetadata(
                bundleIdentifier: identity.bundleIdentifier, name: identity.localizedName, version: nil,
                pluginAPIVersion: nil, readme: nil, readmeBaseURL: nil, icon: .none, containerURL: nil, isDevelopment: false
            )
        }
    }

    private func loadMetadata() async {
        let requests = identities.map { ($0.bundleIdentifier, $0.localizedName) }
        let loaded = await Task.detached(priority: .userInitiated) {
            requests.map { InstalledExtensionMetadata.load(bundleIdentifier: $0.0, localizedName: $0.1) }
        }.value
        guard !Task.isCancelled else { return }
        metadata = Dictionary(loaded.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { _, new in new })
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Extensions")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                Text("Native ExtensionKit contributors enabled for RxCode workspaces.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await loadMetadata() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.bordered)
            .help("Refresh")

            Button {
                showingBrowser = true
            } label: {
                Label("Manage Extensions…", systemImage: "puzzlepiece.extension")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Installed")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Spacer()
                let incompatible = items.filter { !$0.compatibility.isCompatible }.count
                if incompatible > 0 {
                    Label("\(incompatible) need attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.statusWarning)
                }
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Enabled Extensions", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Use Manage Extensions to enable an installed contributor, or ask an agent to create one in a project chat.")
                } actions: {
                    Button("Manage Extensions…") { showingBrowser = true }
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { ClaudeThemeDivider().padding(.leading, 64) }
                        Button { selected = item } label: { ExtensionRow(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ClaudeTheme.borderSubtle))
            }
        }
    }
}

// MARK: - Plugin API

private struct PluginAPICard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: ClaudeTheme.size(16)))
                    .foregroundStyle(ClaudeTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Supported Plugin API")
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                APIVersionBadge(version: ExtensionPluginAPI.version, compatible: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(ExtensionPluginAPI.capabilities) { capability in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: capability.symbol)
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: capability.title)
                                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                            Text(verbatim: capability.detail)
                                .font(.system(size: ClaudeTheme.size(10.5)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ClaudeTheme.surfaceTertiary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ClaudeTheme.borderSubtle))
    }

    private var subtitle: String {
        #if DEBUG
        "Debug build tracks the unreleased API on main. Release builds support \(ExtensionPluginAPI.releaseVersion)."
        #else
        "Extensions built for a different plugin API show a compatibility warning."
        #endif
    }
}

private struct APIVersionBadge: View {
    let version: String?
    let compatible: Bool

    var body: some View {
        HStack(spacing: 4) {
            if !compatible {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(verbatim: version.map { "API \($0)" } ?? "API unknown")
        }
        .font(.system(size: ClaudeTheme.size(10.5), weight: .semibold, design: .monospaced))
        .foregroundStyle(compatible ? ClaudeTheme.accentText : ClaudeTheme.statusWarning)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((compatible ? ClaudeTheme.accentSubtle : ClaudeTheme.statusWarning.opacity(0.14)), in: Capsule())
    }
}

// MARK: - Rows

private struct ExtensionRow: View {
    let item: InstalledExtensionMetadata
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ExtensionIconView(icon: item.icon, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: item.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .lineLimit(1)
                    if item.isDevelopment {
                        Text("Development")
                            .font(.system(size: ClaudeTheme.size(9.5), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(ClaudeTheme.border))
                    }
                }
                Text(verbatim: item.bundleIdentifier)
                    .font(.system(size: ClaudeTheme.size(10.5), design: .monospaced))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            APIVersionBadge(version: item.pluginAPIVersion, compatible: item.compatibility.isCompatible)
                .help(ExtensionPluginAPI.warning(for: item.compatibility) ?? "Compatible with this RxCode build.")
            Image(systemName: "chevron.right")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(hovering ? ClaudeTheme.sidebarItemHover : .clear)
        .onHover { hovering = $0 }
    }
}

struct ExtensionIconView: View {
    let icon: InstalledExtensionMetadata.Icon
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [ClaudeTheme.accent.opacity(0.85), ClaudeTheme.accent.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: size * 0.48))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        switch icon {
        case .image(let url): NSImage(contentsOf: url)
        case .application(let url): NSWorkspace.shared.icon(forFile: url.path)
        case .none: nil
        }
    }
}

// MARK: - Detail

private struct ExtensionDetailSheet: View {
    let item: InstalledExtensionMetadata
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if let warning = ExtensionPluginAPI.warning(for: item.compatibility) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ClaudeTheme.statusWarning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compatibility Warning")
                                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                            Text(verbatim: warning)
                                .font(.system(size: ClaudeTheme.size(11)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(ClaudeTheme.statusWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                ClaudeThemeDivider()
                readme
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let container = item.containerURL {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([container])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ExtensionIconView(icon: item.icon, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.name)
                    .font(.system(size: ClaudeTheme.size(18), weight: .semibold))
                Text(verbatim: item.bundleIdentifier)
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    APIVersionBadge(version: item.pluginAPIVersion, compatible: item.compatibility.isCompatible)
                    Text(verbatim: "Host API \(ExtensionPluginAPI.version)")
                        .font(.system(size: ClaudeTheme.size(10.5)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    if let version = item.version {
                        Text(verbatim: "· Version \(version)")
                            .font(.system(size: ClaudeTheme.size(10.5)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder private var readme: some View {
        if let text = item.readme, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownPreviewView(content: text, baseURL: item.readmeBaseURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No README", systemImage: "doc.text",
                                   description: Text("This extension does not include a README.md."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
