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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage").font(.headline)
                Spacer()
                Button("Manage cards", systemImage: "slider.horizontal.3") { managing = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await appState.refreshUsagePlugins() } }
                    .disabled(appState.usagePluginsRefreshing)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], alignment: .leading) {
                ForEach(visibleCards) { card in
                    if let snapshot = appState.usageDashboard.snapshot(for: card) {
                        UsageDashboardCard(snapshot: snapshot, configuration: card)
                            .contextMenu {
                                Button("Edit card…") { editingCard = card }
                                Menu("Card style") {
                                    ForEach(UsageCardConfiguration.styles, id: \.self) { style in
                                        Button(style.capitalized) { setStyle(style, card: card) }
                                    }
                                }
                                Button("Add another view…") {
                                    var copy = card; copy.id = UUID(); editingCard = copy
                                }
                            }
                    }
                }
            }
            if visibleCards.isEmpty {
                ContentUnavailableView("No usage cards", systemImage: "chart.bar",
                    description: Text("Manage cards to add an integration or show a card for these projects."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay { if appState.usagePluginsRefreshing { ProgressView("Refreshing usage…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .overlay { if updatingStyle { ProgressView("Updating card…").padding().background(.regularMaterial) } }
        .sheet(isPresented: $managing) { UsageDashboardManager() }
        .sheet(item: $editingCard) { UsageCardEditor(card: $0) }
        .alert("Usage cards", isPresented: Binding(get: { appState.usageDashboardError != nil }, set: { if !$0 { appState.usageDashboardError = nil } })) {
            Button("OK") { appState.usageDashboardError = nil }
        } message: { Text(appState.usageDashboardError ?? "") }
    }
    private func setStyle(_ style: String, card: UsageCardConfiguration) {
        var dashboard = appState.usageDashboard
        guard let index = dashboard.cards.firstIndex(where: { $0.id == card.id }) else { return }
        dashboard.cards[index].style = style
        updatingStyle = true
        Task { _ = await appState.updateUsageDashboard(dashboard); updatingStyle = false }
    }
}
