import SwiftUI
import RxCodeCore

struct UsageDashboardView: View {
    @Environment(AppState.self) private var appState
    let projectIds: Set<UUID>
    @State private var managing = false
    @State private var updatingStyle = false
    @State private var editingCard: UsageCardConfiguration?
    private var visibleCards: [UsageCardConfiguration] {
        appState.usageDashboard.visibleCards(projectIDs: projectIds)
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
                    if let snapshot = appState.usageDashboard.snapshot(for: card) {
                        UsageDashboardCard(snapshot: snapshot, configuration: card,
                                           isRefreshing: appState.usagePlugins.refreshingIntegrationIDs.contains(card.integrationID))
                            .usageCardSize(card.cardSize)
                            .contextMenu {
                                Button("Edit card…") { editingCard = card }
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
