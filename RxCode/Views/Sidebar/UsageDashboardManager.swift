import SwiftUI
import RxCodeCore

struct UsageDashboardManager: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var adding = false
    @State private var editing: UsageIntegration?
    @State private var card: UsageCardConfiguration?
    @State private var deleting: UsageIntegration?
    @State private var busy = false
    @State private var error: String?

    private var selected: UsageIntegration? {
        appState.usageDashboard.integrations.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Integrations") {
                    ForEach(appState.usageDashboard.integrations) { integration in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(integration.title).font(.headline)
                            Text(integration.pluginID).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(integration.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button("Add integration", systemImage: "plus") { adding = true }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity).padding()
            }
        } detail: {
            if let selected {
                integrationCards(selected)
            } else {
                ContentUnavailableView("Choose an integration", systemImage: "square.grid.2x2",
                    description: Text("Select a connection or add one to create your usage cards."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Manage usage cards")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) }
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 600, idealHeight: 680, maxHeight: .infinity)
        .onAppear { selectedID = selectedID ?? appState.usageDashboard.integrations.first?.id }
        .sheet(isPresented: $adding) { UsageIntegrationEditor(integration: .init(pluginID: "neon", title: "Neon")) }
        .sheet(item: $editing) { UsageIntegrationEditor(integration: $0) }
        .sheet(item: $card) { UsageCardEditor(card: $0) }
        .confirmationDialog("Remove this integration and all its cards?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { integration in
            Button("Remove integration", role: .destructive) { remove(integration) }
        }
        .overlay {
            if busy { ProgressView("Removing integration…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
        }
        .disabled(busy)
        .alert("Could not update integration", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func integrationCards(_ integration: UsageIntegration) -> some View {
        let cards = appState.usageDashboard.cards.filter { $0.integrationID == integration.id }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(integration.title).font(.title2.bold())
                    Text(integration.account.isEmpty ? "Local usage" : integration.account)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Edit connection…") { editing = integration }
                    Button("Remove integration…", role: .destructive) { deleting = integration }
                } label: { Label("Connection", systemImage: "gearshape") }
            }.padding(20)
            Divider()
            if cards.isEmpty {
                ContentUnavailableView("No card views", systemImage: "rectangle.on.rectangle",
                    description: Text("Add a card view to choose a metric, style, and where it appears."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 20) {
                        ForEach(cards) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                if let snapshot = appState.usageDashboard.snapshot(for: item) {
                                    UsageDashboardCard(snapshot: snapshot, configuration: item)
                                } else {
                                    Label("Waiting for usage data", systemImage: "chart.bar")
                                        .frame(maxWidth: .infinity, minHeight: 120).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                                }
                                HStack {
                                    Text(item.style.capitalized).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button("Edit view…") { card = item }
                                        .accessibilityIdentifier("edit-usage-card-\(item.id.uuidString)")
                                }
                                Text(visibility(item)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(20)
                }
            }
            Divider()
            HStack {
                Text("Each view has its own style, metric, and visibility.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add card view", systemImage: "plus") { card = .init(integrationID: integration.id) }
                    .buttonStyle(.borderedProminent)
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func visibility(_ card: UsageCardConfiguration) -> String {
        let places = [(card.isVisible, "Briefing"), (card.showInMenuBar, "Menu bar"), (card.showInWidget, "Widget")]
            .filter(\.0).map(\.1)
        return places.isEmpty ? "Hidden from all surfaces" : places.joined(separator: " · ")
    }

    private func remove(_ integration: UsageIntegration) {
        busy = true
        Task {
            defer { busy = false }
            do {
                var dashboard = appState.usageDashboard
                dashboard.integrations.removeAll { $0.id == integration.id }
                dashboard.cards.removeAll { $0.integrationID == integration.id }
                dashboard.snapshots.removeAll { $0.id == integration.id }
                guard await appState.updateUsageDashboard(dashboard) else { error = appState.usageDashboardError; return }
                selectedID = dashboard.integrations.first?.id
                try await UsageDashboardStore.shared.deleteCredential(id: integration.id)
                try await UsageOAuthTokens.shared.delete(integration.id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
