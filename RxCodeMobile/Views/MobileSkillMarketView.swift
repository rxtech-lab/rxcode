import SwiftUI
import RxCodeCore
import RxCodeSync

/// Browse the paired desktop's skill marketplace and install or remove skills
/// remotely. The catalog is fetched lazily when the screen first opens.
struct MobileSkillMarketView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var searchText = ""

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
    }

    private var filteredPlugins: [MobileSkillPlugin] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.skillCatalog }
        return state.skillCatalog.filter {
            $0.name.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || $0.categoryLabel.lowercased().contains(query)
        }
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
