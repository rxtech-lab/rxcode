import RxCodeCore
import SwiftUI

/// Skill marketplace panel — displayed as an overlay or embedded in a settings tab.
struct SkillMarketView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedFilter = "All"
    @State private var selectedPlugin: MarketplacePlugin?
    @State private var showGitSourceSheet = false

    /// When true, strips overlay-specific styling (rounded corners, shadow, fixed frame)
    /// and hides the close button so the view can be embedded in a parent container.
    var isEmbedded: Bool = false

    var body: some View {
        Group {
            if isEmbedded {
                marketplaceContent
            } else {
                marketplaceContent
                    .frame(width: 860, height: 720)
            }
        }
        .task {
            if appState.marketplaceCatalog.isEmpty {
                await appState.loadMarketplace()
            }
        }
        .sheet(item: $selectedPlugin) { plugin in
            PluginDetailView(
                plugin: plugin
            )
            .focusable(false)
        }
        .sheet(isPresented: $showGitSourceSheet) {
            AddSkillGitSourceSheet()
                .focusable(false)
        }
    }

    private var marketplaceContent: some View {
        VStack(spacing: 0) {
            headerBar
            ClaudeThemeDivider()
            searchAndFilterBar
            if !appState.marketplaceCustomSources.isEmpty || appState.marketplaceSourceError != nil {
                ClaudeThemeDivider()
                customSourcesBar
            }
            ClaudeThemeDivider()
            pluginGrid
                .overlay {
                    if appState.marketplaceLoading && !appState.marketplaceCatalog.isEmpty {
                        ProgressView("Refreshing catalog...")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: ClaudeTheme.size(16)))
                .foregroundStyle(ClaudeTheme.accent)

            Text("Skill Marketplace")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))

            Spacer()

            Button {
                showGitSourceSheet = true
            } label: {
                Label("Add Git Source", systemImage: "plus")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add a skill catalog from a GitHub repository")

            Button {
                Task { await appState.loadMarketplace(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(appState.marketplaceLoading)
            .help("Refresh")

            if !isEmbedded {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Search & Filter

    private var searchAndFilterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)

                TextField("Search skills...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(13)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ClaudeTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ClaudeTheme.border.opacity(0.5), lineWidth: 1)
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip("All")
                    filterChip("Installed")

                    ForEach(availableMarketplaces, id: \.self) { label in
                        filterChip(label)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var customSourcesBar: some View {
        if !appState.marketplaceCustomSources.isEmpty || appState.marketplaceSourceError != nil {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)

                if appState.marketplaceCustomSources.isEmpty {
                    Text("No custom Git sources")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(appState.marketplaceCustomSources.count) custom Git source\(appState.marketplaceCustomSources.count == 1 ? "" : "s")")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let error = appState.marketplaceSourceError {
                    Text(error)
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.statusError)
                        .lineLimit(1)
                }

                Spacer()

                Button("Manage") {
                    showGitSourceSheet = true
                }
                .font(.system(size: ClaudeTheme.size(12)))
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(ClaudeTheme.surfacePrimary.opacity(0.45))
        }
    }

    private func filterChip(_ label: String) -> some View {
        Button {
            selectedFilter = label
        } label: {
            Text(LocalizedStringKey(label))
                .font(.system(size: ClaudeTheme.size(11), weight: selectedFilter == label ? .semibold : .regular))
                .foregroundStyle(selectedFilter == label ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selectedFilter == label ? ClaudeTheme.accent : ClaudeTheme.surfaceSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Plugin Grid

    private var pluginGrid: some View {
        Group {
            if appState.marketplaceLoading && appState.marketplaceCatalog.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading catalog...")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredPlugins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: ClaudeTheme.size(24)))
                        .foregroundStyle(.secondary)
                    Text("No results found")
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        ForEach(filteredPlugins) { plugin in
                            PluginCard(
                                plugin: plugin,
                                isInstalled: appState.marketplaceInstalledNames.contains(plugin.name),
                                installStatus: appState.marketplacePluginStates[plugin.id] ?? .notInstalled
                            )
                            .onTapGesture {
                                selectedPlugin = plugin
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var filteredPlugins: [MarketplacePlugin] {
        var plugins = appState.marketplaceCatalog

        if selectedFilter == "Installed" {
            plugins = plugins.filter { appState.marketplaceInstalledNames.contains($0.name) }
        } else if selectedFilter != "All" {
            plugins = plugins.filter { $0.marketplaceLabel == selectedFilter }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            plugins = plugins.filter {
                $0.name.lowercased().contains(query) ||
                    $0.description.lowercased().contains(query) ||
                    $0.author.lowercased().contains(query) ||
                    $0.category.lowercased().contains(query)
            }
        }

        return plugins
    }

    private var availableMarketplaces: [String] {
        var counts: [String: Int] = [:]
        for plugin in appState.marketplaceCatalog {
            counts[plugin.marketplaceLabel, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
}

// MARK: - Plugin Card (for grid)

struct PluginCard: View {
    let plugin: MarketplacePlugin
    let isInstalled: Bool
    let installStatus: PluginInstallStatus

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tags
            HStack(spacing: 4) {
                Text(plugin.categoryLabel)
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ClaudeTheme.accent.opacity(0.08))
                    .clipShape(Capsule())

                Text(plugin.marketplaceLabel)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ClaudeTheme.surfacePrimary)
                    .clipShape(Capsule())

                Spacer()
            }

            // Name
            Text(plugin.name)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))

            // Description
            Text(plugin.description)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            // Bottom info
            HStack(spacing: 6) {
                Image(systemName: "person")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
                Text(plugin.author)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)

                Spacer()

                installBadge
            }
        }
        .padding(14)
        .background(ClaudeTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(ClaudeTheme.border.opacity(isHovering ? 0.8 : 0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var installBadge: some View {
        switch installStatus {
        case .notInstalled:
            if isInstalled {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Installed")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                }
            }
        case .installing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Installing...")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
            }
        case .installed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                Text("Installed")
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
            }
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.statusError)
                Text("Failed")
                    .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
            .help(message)
        }
    }
}

// MARK: - Plugin Detail View

struct PluginDetailView: View {
    let plugin: MarketplacePlugin

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private var isInstalled: Bool {
        appState.marketplaceInstalledNames.contains(plugin.name)
    }

    private var installStatus: PluginInstallStatus {
        appState.marketplacePluginStates[plugin.id] ?? .notInstalled
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        Text("Back")
                            .font(.system(size: ClaudeTheme.size(13)))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Spacer()

                actionButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ClaudeThemeDivider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Category
                    HStack(spacing: 6) {
                        Text(plugin.categoryLabel)
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ClaudeTheme.accent.opacity(0.08))
                            .clipShape(Capsule())

                        Text(plugin.sourceType.rawValue)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ClaudeTheme.surfacePrimary)
                            .clipShape(Capsule())
                    }

                    // Name
                    Text(plugin.name)
                        .font(.system(size: ClaudeTheme.size(22), weight: .bold))

                    // Description
                    Text(plugin.description)
                        .font(.system(size: ClaudeTheme.size(14)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ClaudeThemeDivider()

                    // Info grid
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        infoRow(label: "Author", value: plugin.author)
                        infoRow(label: "Market", value: plugin.marketplace)
                        infoRow(label: "Category", value: plugin.categoryLabel)
                        if !plugin.homepage.isEmpty {
                            infoRow(label: "Homepage", value: plugin.homepage)
                        }
                    }

                    ClaudeThemeDivider()

                    // Install command
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agent Availability")
                            .font(.system(size: ClaudeTheme.size(12), weight: .semibold))

                        Text("Installed skills are managed by RxCode, sourced from OpenAI Agent Skills and compatible catalogs, and enabled for Claude Code, Codex, and ACP agents where supported.")
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ClaudeTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 620, height: 500)
    }

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var removeButton: some View {
        Button("Remove") {
            Task { await appState.uninstallMarketplacePlugin(plugin) }
        }
        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
        .foregroundStyle(ClaudeTheme.statusError)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch installStatus {
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing...")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(.secondary)
            }
        case .installed:
            removeButton
        case .notInstalled where isInstalled:
            removeButton
        case .failed:
            Button("Retry") {
                Task { await appState.installMarketplacePlugin(plugin) }
            }
            .buttonStyle(.borderedProminent)
        default:
            Button("Install") {
                Task { await appState.installMarketplacePlugin(plugin) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    SkillMarketView()
        .environment(AppState())
        .frame(width: 860, height: 720)
}
