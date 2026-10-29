import SwiftUI
import RxCodeCore

struct UsageCardEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var card: UsageCardConfiguration
    @State private var deleting = false
    @State private var saving = false
    @State private var error: String?
    @State private var name = ""

    private var snapshot: UsagePluginSnapshot? { appState.usageDashboard.snapshot(for: card) }
    private var existing: Bool { appState.usageDashboard.cards.contains { $0.id == card.id } }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Form {
                    Section("Integration") {
                        TextField("Name", text: $name)
                        Text("Renaming applies to every card view of this integration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Appearance") {
                        Picker("Style", selection: $card.style) {
                            ForEach(UsageCardConfiguration.styles, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        Text(styleDescription).font(.caption).foregroundStyle(.secondary)
                        Picker("Size", selection: Binding(get: { card.size ?? "default" },
                                                          set: { card.size = $0 == "default" ? nil : $0 })) {
                            Text("Default (\(UsageCardSize.defaultSize(forStyle: card.style).title))").tag("default")
                            ForEach(UsageCardSize.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        Text("Like widgets, cards take 1 to 4 grid cells and the briefing arranges them to fill gaps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Metrics") {
                        Toggle("All metrics", isOn: Binding(
                            get: { card.selectedMetricIDs.isEmpty },
                            set: { card.selectMetrics($0 ? [] : Array(availableMetricIDs.prefix(1))) }
                        )).disabled(availableMetricIDs.isEmpty)
                        ForEach(availableMetricIDs, id: \.self) { id in
                            Toggle(snapshot?.metrics.first { $0.id == id }?.title ?? "\(id) (unavailable)",
                                   isOn: metricBinding(id))
                                .disabled(selectedIDs.count == 1 && selectedIDs.contains(id))
                        }
                        Text("Select one or more metrics. All metrics also includes new metrics when they become available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Show in") {
                        Toggle("Briefing", isOn: $card.isVisible)
                        Toggle("Menu bar", isOn: $card.showInMenuBar)
                        Toggle("Widget", isOn: $card.showInWidget)
                    }
                    if existing {
                        Section {
                            Button("Delete card view…", role: .destructive) { deleting = true }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Live preview").font(.headline)
                    Text("Changes appear here as you edit. Click the card to preview its details.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let snapshot {
                        ScrollView([.horizontal, .vertical]) {
                            UsageCardGridLayout(maximumColumns: card.cardSize.columns) {
                                UsageDashboardCard(snapshot: snapshot, configuration: card, allowsEditing: false)
                                    .usageCardSize(card.cardSize)
                            }
                            .frame(width: previewWidth)
                            .frame(maxWidth: .infinity)
                        }
                        Text("The preview uses the latest saved usage. Widget layouts adapt to the widget size.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("No preview data yet", systemImage: "chart.bar",
                            description: Text("Save the connection and refresh its usage to preview this card."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.quaternary.opacity(0.2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(existing ? "Edit card view" : "Add card view")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(remove: false) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 620, maxHeight: .infinity)
        .interactiveDismissDisabled(saving)
        .onAppear { name = appState.usageDashboard.integrations.first { $0.id == card.integrationID }?.title ?? "" }
        .confirmationDialog("Delete this card view?", isPresented: $deleting) {
            Button("Delete card", role: .destructive) { save(remove: true) }
        }
        .overlay {
            if saving { ProgressView("Updating card…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
        }
        .alert("Could not save card", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var styleDescription: String {
        switch card.style {
        case "compact": "Shows only the first selected metric. Defaults to the small size."
        case "metrics": "A table of the selected metrics, with usage bars for percentages. Defaults to the large size."
        default: "A headline value with supporting metrics. Defaults to the medium size."
        }
    }

    /// Matches the card's footprint on a briefing grid with 160 pt cells.
    private var previewWidth: CGFloat {
        let columns = CGFloat(card.cardSize.columns)
        return columns * 160 + (columns - 1) * 12
    }

    private var availableMetricIDs: [String] {
        let current = snapshot?.metrics.map(\.id) ?? []
        return current + card.selectedMetricIDs.filter { !current.contains($0) }
    }

    private var selectedIDs: [String] {
        card.selectedMetricIDs.isEmpty ? availableMetricIDs : card.selectedMetricIDs
    }

    private func metricBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { card.includesMetric(id) }, set: { selected in
            var ids = selectedIDs
            if selected { if !ids.contains(id) { ids.append(id) } }
            else { ids.removeAll { $0 == id } }
            if !ids.isEmpty { card.selectMetrics(ids) }
        })
    }

    private func save(remove: Bool) {
        saving = true
        var dashboard = appState.usageDashboard
        if let index = dashboard.cards.firstIndex(where: { $0.id == card.id }) {
            if remove { dashboard.cards.remove(at: index) } else { dashboard.cards[index] = card }
        } else if !remove { dashboard.cards.append(card) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remove, !title.isEmpty, let index = dashboard.integrations.firstIndex(where: { $0.id == card.integrationID }) {
            dashboard.integrations[index].title = title
            for i in dashboard.snapshots.indices where dashboard.snapshots[i].id == card.integrationID {
                dashboard.snapshots[i].title = title
            }
        }
        Task {
            let saved = await appState.updateUsageDashboard(dashboard)
            saving = false
            if saved { dismiss() } else { error = appState.usageDashboardError }
        }
    }
}
