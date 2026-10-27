import SwiftUI
import RxCodeCore

struct UsageDashboardView: View {
    @Environment(AppState.self) private var appState
    let projectIds: Set<UUID>
    @State private var managing = false
    @State private var showingAIDetails = false
    @State private var updatingStyle = false
    @State private var editingCard: UsageCardConfiguration?
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
                ForEach(appState.usageDashboard.cards.filter(\.isVisible)) { card in
                    if let snapshot = appState.usageDashboard.snapshot(for: card),
                       projectIds.isEmpty || snapshot.projectID == nil || projectIds.contains(snapshot.projectID!) {
                        UsagePluginCard(snapshot: snapshot, configuration: card)
                            .contextMenu {
                                if snapshot.pluginID.hasPrefix("ai-") {
                                    Button("AI usage breakdown…") { showingAIDetails = true }
                                }
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
        }
        .overlay { if appState.usagePluginsRefreshing { ProgressView("Refreshing usage…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .sheet(isPresented: $showingAIDetails) {
            NavigationStack {
                ScrollView { BriefingUsageStatsView(projectIds: projectIds).padding() }
                    .navigationTitle("AI usage breakdown")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAIDetails = false } } }
            }.frame(minWidth: 780, minHeight: 540, maxHeight: .infinity)
        }
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

struct UsageDashboardManager: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: UsageIntegration?
    @State private var card: UsageCardConfiguration?
    @State private var deleting: UsageIntegration?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.usageDashboard.integrations) { integration in
                    Section(integration.title) {
                        ForEach(appState.usageDashboard.cards.filter { $0.integrationID == integration.id }) { item in
                            Button { card = item } label: {
                                HStack {
                                    Text(item.style.capitalized)
                                    Spacer()
                                    Text(item.isVisible ? "Visible" : "Hidden").foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Add card view") { card = .init(integrationID: integration.id) }
                        Button("Edit integration…") { editing = integration }
                        Button("Remove integration…", role: .destructive) { deleting = integration }
                    }
                }
            }
            .navigationTitle("Usage integrations")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add integration", systemImage: "plus") { adding = true } }
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .sheet(isPresented: $adding) { UsageIntegrationEditor(integration: .init(pluginID: "neon", title: "Neon")) }
        .sheet(item: $editing) { UsageIntegrationEditor(integration: $0) }
        .sheet(item: $card) { UsageCardEditor(card: $0) }
        .confirmationDialog("Remove this integration and all its cards?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove integration", role: .destructive) {
                guard let integration = deleting else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await UsageDashboardStore.shared.deleteCredential(id: integration.id)
                        try await UsageOAuthTokens.shared.delete(integration.id)
                        var dashboard = appState.usageDashboard
                        dashboard.integrations.removeAll { $0.id == integration.id }
                        dashboard.cards.removeAll { $0.integrationID == integration.id }
                        dashboard.snapshots.removeAll { $0.id == integration.id }
                        _ = await appState.updateUsageDashboard(dashboard)
                    } catch { appState.usageDashboardError = error.localizedDescription }
                }
            }
        }
        .overlay { if busy { ProgressView("Removing integration…").padding().background(.regularMaterial) } }
    }
}

struct UsageCardEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var card: UsageCardConfiguration
    @State private var deleting = false
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("Style", selection: $card.style) {
                    ForEach(UsageCardConfiguration.styles, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Metric", selection: $card.metricID) {
                    Text("All metrics").tag(String?.none)
                    ForEach(appState.usageDashboard.snapshot(for: card)?.metrics ?? []) { metric in
                        Text(metric.title).tag(Optional(metric.id))
                    }
                }
                Toggle("Show in briefing", isOn: $card.isVisible)
                Toggle("Show in menu bar", isOn: $card.showInMenuBar)
                Toggle("Show in widget", isOn: $card.showInWidget)
                if appState.usageDashboard.cards.contains(where: { $0.id == card.id }) {
                    Button("Delete card…", role: .destructive) { deleting = true }
                }
            }.formStyle(.grouped)
            .navigationTitle("Card view")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(remove: false) }.disabled(saving) }
            }
        }
        .frame(minWidth: 480, minHeight: 420, maxHeight: .infinity)
        .confirmationDialog("Delete this card view?", isPresented: $deleting) { Button("Delete card", role: .destructive) { save(remove: true) } }
        .overlay { if saving { ProgressView("Saving…").padding().background(.regularMaterial) } }
    }
    private func save(remove: Bool) {
        saving = true
        var dashboard = appState.usageDashboard
        if let index = dashboard.cards.firstIndex(where: { $0.id == card.id }) {
            if remove { dashboard.cards.remove(at: index) } else { dashboard.cards[index] = card }
        } else if !remove { dashboard.cards.append(card) }
        Task { let saved = await appState.updateUsageDashboard(dashboard); saving = false; if saved { dismiss() } }
    }
}
