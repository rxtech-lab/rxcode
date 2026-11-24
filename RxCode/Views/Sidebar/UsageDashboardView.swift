import SwiftUI
import RxCodeCore

struct UsageDashboardView: View {
    @Environment(AppState.self) private var appState
    let projectIds: Set<UUID>
    @State private var managing = false
    @State private var updatingStyle = false
    @State private var editingCard: UsageCardConfiguration?
    @State private var editingIntegration: UsageIntegration?
    private var visibleCards: [UsageCardConfiguration] {
        guard ExtensionPluginAPI.v2Enabled else { return appState.usageDashboard.visibleCards(projectIDs: projectIds) }
        return appState.usageDashboard.cards.filter { card in
            guard card.isVisible, let integration = appState.usageDashboard.integrations.first(where: { $0.id == card.integrationID }) else { return false }
            return integration.projectID.map { projectIds.isEmpty || projectIds.contains($0) } ?? true
        }
    }
    private func snapshot(for card: UsageCardConfiguration) -> UsagePluginSnapshot? {
        if let saved = appState.usageDashboard.snapshot(for: card) { return saved }
        guard ExtensionPluginAPI.v2Enabled,
              let integration = appState.usageDashboard.integrations.first(where: { $0.id == card.integrationID }) else { return nil }
        return .init(id: integration.id, pluginID: integration.pluginID, title: integration.title, projectID: integration.projectID,
                     scope: integration.account, period: "", fetchedAt: .distantPast, metrics: [])
    }

    var body: some View {
        let _ = BriefingPerformanceLog.log("usage dashboard body\(BriefingTimelineScrollActivity.isAnyScrolling ? " [scrolling]" : ""): \(visibleCards.count) visible cards")
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage").font(.headline)
                Spacer()
                Button("Manage cards", systemImage: "slider.horizontal.3") { managing = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await appState.refreshUsagePlugins() } }
                    .disabled(appState.usagePluginsRefreshing)
            }
            UsageCardGridLayout {
                ForEach(visibleCards) { card in
                    if let snapshot = snapshot(for: card) {
                        UsageDashboardCard(snapshot: snapshot, configuration: card,
                                           isRefreshing: appState.usagePlugins.refreshingIntegrationIDs.contains(card.integrationID))
                            .usageCardSize(card.cardSize)
                            .contextMenu {
                                Button("Edit card…") { editingCard = card }
                                if let integration = appState.usageDashboard.integrations.first(where: { $0.id == card.integrationID }) {
                                    Button("Edit integration…", systemImage: "gearshape") {
                                        BriefingPerformanceLog.log("usage card context menu edit integration: \(integration.id)")
                                        editingIntegration = integration
                                    }
                                    .accessibilityIdentifier("usage-card-context-edit-integration-\(card.id.uuidString)")
                                }
                                Menu("Card style") {
                                    ForEach(UsageCardConfiguration.styles, id: \.self) { style in
                                        Button(style.capitalized) { update(card) { $0.style = style } }
                                    }
                                }
                                Menu("Card size") {
                                    Button("Default") { update(card) { $0.size = nil } }
                                    ForEach(UsageCardSize.allCases) { size in
                                        Button(size.title) { update(card) { $0.size = size.rawValue } }
                                    }
                                }
                                Button("Add another view…") {
                                    var copy = card; copy.id = UUID(); editingCard = copy
                                }
                            }
                    }
                }
            }
            .animation(.snappy, value: visibleCards)
            if visibleCards.isEmpty {
                ContentUnavailableView("No usage cards", systemImage: "chart.bar",
                    description: Text("Manage cards to add an integration or show a card for these projects."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay { if updatingStyle { ProgressView("Updating card…").padding().background(.regularMaterial) } }
        .sheet(isPresented: $managing) { UsageDashboardManager() }
        .sheet(item: $editingCard) { UsageCardEditor(card: $0) }
        .sheet(item: $editingIntegration) { UsageIntegrationEditor(integration: $0) }
        .alert("Usage cards", isPresented: Binding(get: { appState.usageDashboardError != nil }, set: { if !$0 { appState.usageDashboardError = nil } })) {
            Button("OK") { appState.usageDashboardError = nil }
        } message: { Text(appState.usageDashboardError ?? "") }
    }
    private func update(_ card: UsageCardConfiguration, _ change: (inout UsageCardConfiguration) -> Void) {
        var dashboard = appState.usageDashboard
        guard let index = dashboard.cards.firstIndex(where: { $0.id == card.id }) else { return }
        change(&dashboard.cards[index])
        updatingStyle = true
        Task { _ = await appState.updateUsageDashboard(dashboard); updatingStyle = false }
    }
}
