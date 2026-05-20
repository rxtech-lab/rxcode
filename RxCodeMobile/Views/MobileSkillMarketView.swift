import SwiftUI
import RxCodeCore
import RxCodeSync

/// Browse the paired desktop's skill marketplace and install or remove skills
/// remotely. The catalog is fetched lazily when the screen first opens.
struct MobileSkillMarketView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var searchText = ""
    @State private var selectedFilter = "All"
    @State private var showingGitSourceSheet = false

    var body: some View {
        List {
            if let error = state.skillCatalogError {
                errorRow(error)
            }
            if let error = state.lastSkillError {
                errorRow(error)
            }

            if state.skillCatalog.isEmpty {
                emptyOrLoadingRow
            } else if filteredPlugins.isEmpty {
                Text("No skills found.").foregroundStyle(.secondary)
            } else {
                ForEach(groupedCategories, id: \.self) { category in
                    Section(category) {
                        ForEach(plugins(in: category)) { plugin in
                            row(plugin)
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search skills")
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingGitSourceSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Git Source")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if state.skillCatalogLoading {
                    ProgressView()
                }
            }
        }
        .refreshable {
            await state.requestSkillCatalog(forceRefresh: true)
        }
        .task {
            if state.skillCatalog.isEmpty {
                await state.requestSkillCatalog()
            }
        }
        .sheet(isPresented: $showingGitSourceSheet) {
            MobileSkillGitSourceSheet()
                .environmentObject(state)
        }
    }

    private var filteredPlugins: [MobileSkillPlugin] {
        var plugins = state.skillCatalog

        if selectedFilter == "Installed" {
            plugins = plugins.filter(\.isInstalled)
        } else if selectedFilter != "All" {
            plugins = plugins.filter { $0.marketplaceLabel == selectedFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return plugins }
        return plugins.filter {
            $0.name.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || $0.categoryLabel.lowercased().contains(query)
                || $0.marketplaceLabel.lowercased().contains(query)
        }
    }

    private var availableMarketplaces: [String] {
        var counts: [String: Int] = [:]
        for plugin in state.skillCatalog {
            counts[plugin.marketplaceLabel, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                selectedFilter = "All"
            } label: {
                if selectedFilter == "All" {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }

            Button {
                selectedFilter = "Installed"
            } label: {
                if selectedFilter == "Installed" {
                    Label("Installed", systemImage: "checkmark")
                } else {
                    Text("Installed")
                }
            }

            if !availableMarketplaces.isEmpty {
                Section("Marketplaces") {
                    ForEach(availableMarketplaces, id: \.self) { label in
                        Button {
                            selectedFilter = label
                        } label: {
                            if selectedFilter == label {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: selectedFilter == "All" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter Skills")
    }

    /// Distinct category labels in display order (alphabetical).
    private var groupedCategories: [String] {
        Set(filteredPlugins.map(\.categoryLabel)).sorted()
    }

    private func plugins(in category: String) -> [MobileSkillPlugin] {
        filteredPlugins
            .filter { $0.categoryLabel == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var emptyOrLoadingRow: some View {
        if state.skillCatalogLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading skills…").foregroundStyle(.secondary)
            }
        } else if state.skillCatalogError == nil {
            Text("No skills found.").foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
    }

    private func row(_ plugin: MobileSkillPlugin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(plugin.name).font(.headline)
                Spacer()
                control(plugin)
            }
            if !plugin.summary.isEmpty {
                Text(plugin.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(plugin.marketplaceLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func control(_ plugin: MobileSkillPlugin) -> some View {
        if state.inFlightSkillMutations.contains(plugin.id) {
            ProgressView()
        } else if plugin.isInstalled {
            Button("Remove", role: .destructive) {
                Task { await state.uninstallSkill(plugin.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button("Install") {
                Task { await state.installSkill(plugin.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

private struct MobileSkillGitSourceSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var gitURL = ""
    @State private var ref = ""

    private var canAdd: Bool {
        !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !state.inFlightSkillSourceMutations.contains(addKey)
    }

    private var addKey: String {
        "add:\(gitURL.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repo", text: $gitURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                    TextField("main", text: $ref)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Git Source")
                } footer: {
                    Text("Use a GitHub repository that exposes .claude-plugin/marketplace.json.")
                }

                if let error = state.lastSkillError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Custom Sources") {
                    if state.skillSources.isEmpty {
                        Text("No custom Git sources added.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.skillSources) { source in
                            HStack {
                                Text(source.displayName)
                                    .lineLimit(1)
                                Spacer()
                                if state.inFlightSkillSourceMutations.contains(source.id) {
                                    ProgressView()
                                } else {
                                    Button(role: .destructive) {
                                        Task { await state.removeSkillGitSource(source.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(source.displayName)")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Git Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let submittedKey = addKey
                            await state.addSkillGitSource(url: gitURL, ref: ref)
                            if state.inFlightSkillSourceMutations.contains(submittedKey) {
                                gitURL = ""
                                ref = ""
                            }
                        }
                    } label: {
                        if state.inFlightSkillSourceMutations.contains(addKey) {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}
