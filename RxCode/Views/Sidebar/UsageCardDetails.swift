import SwiftUI
import RxCodeCore

/// Keeps the popover anchored to the card, including in the menu bar and editor.
struct UsageDashboardCard: View {
    let snapshot: UsagePluginSnapshot
    let configuration: UsageCardConfiguration
    var allowsEditing = true
    var isRefreshing = false
    @State private var showingDetails = false
    @State private var editing = false

    var body: some View {
        Button { showingDetails = true } label: {
            UsagePluginCard(snapshot: snapshot, configuration: configuration,
                showsDetailIndicator: true, reservesEditControlSpace: allowsEditing,
                isRefreshing: isRefreshing)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help("Show \(snapshot.title) details")
        .accessibilityIdentifier("usage-card-\(configuration.id.uuidString)")
        .overlay(alignment: .topTrailing) {
            if allowsEditing {
                Button {
                    editing = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption).padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Edit this card view")
                .accessibilityLabel("Edit \(snapshot.title) card view")
                .accessibilityIdentifier("usage-card-edit-\(configuration.id.uuidString)")
                .padding(8)
            }
        }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            UsageCardDetailPopover(snapshot: snapshot, configuration: configuration, allowsEditing: allowsEditing) {
                showingDetails = false
                editing = true
            }
        }
        .sheet(isPresented: $editing) { UsageCardEditor(card: configuration) }
    }
}

private struct UsageCardDetailPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let snapshot: UsagePluginSnapshot
    let configuration: UsageCardConfiguration
    let allowsEditing: Bool
    let onEdit: () -> Void
    @State private var plugin: (any UsagePlugin)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage details").font(.headline)
                Spacer()
                if allowsEditing { Button("Edit view…", systemImage: "slider.horizontal.3", action: onEdit) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            ScrollView {
                if let plugin {
                    plugin.detailView(snapshot: snapshot, configuration: configuration)
                } else {
                    UsagePluginDetailView(snapshot: snapshot, configuration: configuration)
                }
            }
        }
        .frame(width: snapshot.pluginID.hasPrefix("ai-") ? 720 : 520, height: 560)
        .task(id: snapshot.pluginID) {
            plugin = await appState.usagePluginRegistry.plugin(id: snapshot.pluginID)
        }
    }
}

struct AIUsagePluginDetail: View {
    @Environment(AppState.self) private var appState
    let snapshot: UsagePluginSnapshot
    let configuration: UsageCardConfiguration

    var body: some View {
        let summary = appState.usageSummary(range: .week, projectIds: snapshot.projectID.map { [$0] } ?? [])
        let metric = configuration.selectedMetricIDs.first ?? "top-model"
        let unit = metric == "time" ? "seconds" : (metric == "tokens" ? "tokens" : "turns")
        let models = summary.models.map { model in
            let value = metric == "time" ? model.sessionSeconds : Double(metric == "tokens" ? model.totalTokens : model.turns)
            return (id: model.id,
                    label: appState.usageModelDisplayName(model.model, provider: AgentProvider(rawValue: model.providerRaw) ?? .acp),
                    detail: Optional(AgentProvider(rawValue: model.providerRaw)?.displayNameText ?? model.providerRaw), value: value)
        }
        let providers = summary.providers.map { provider in
            let value = metric == "time" ? provider.sessionSeconds : Double(metric == "tokens" ? provider.totalTokens : provider.turns)
            return (id: provider.providerRaw,
                    label: AgentProvider(rawValue: provider.providerRaw)?.displayNameText ?? provider.providerRaw,
                    detail: String?.none, value: value)
        }
        if summary.isEmpty {
            ContentUnavailableView("No AI usage yet", systemImage: "chart.pie",
                description: Text("Model and provider breakdowns appear after agent activity."))
                .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        } else {
            UsageBreakdownPopover(
                title: snapshot.metrics.first { $0.id == metric }?.title ?? snapshot.title,
                subtitle: "Last 7 days · \(snapshot.scope)",
                charts: [
                    .init(title: "By model", unit: unit, slices: UsageBreakdownPopover.Slice.folded(models)),
                    .init(title: "By provider", unit: unit, slices: UsageBreakdownPopover.Slice.folded(providers))
                ])
        }
    }
}

struct AILimitsPluginDetail: View {
    let configuration: UsageCardConfiguration
    @State private var selection = "history"

    var body: some View {
        VStack {
            Picker("Details", selection: $selection) {
                Text("History").tag("history")
                Text("Task costs").tag("costs")
                Text("Model estimates").tag("models")
            }.pickerStyle(.segmented).padding()
            switch selection {
            case "costs": RateLimitTaskCostPopover(providers: AppState.rateLimitedProviders, range: .week)
            case "models": RateLimitModelEstimatePopover(providers: AppState.rateLimitedProviders, range: .week)
            default: RateLimitHistoryPopover(providers: AppState.rateLimitedProviders, range: .week)
            }
        }
        .onAppear {
            if configuration.selectedMetricIDs.first?.hasSuffix(":cost") == true { selection = "costs" }
            if configuration.selectedMetricIDs.first?.hasSuffix(":remaining") == true { selection = "models" }
        }
    }
}
