import Foundation
import RxCodeCore

extension AppState {
    func handleUsageCards(_ arguments: JSONValue) async throws -> JSONValue {
        var dashboard = usageDashboard
        let operation = arguments["operation"]?.stringValue ?? "get"
        if operation == "delete_card" {
            guard let raw = arguments["card_id"]?.stringValue, let id = UUID(uuidString: raw),
                  dashboard.cards.contains(where: { $0.id == id }) else { throw IDEToolError.invalidArguments("A valid card_id is required.") }
            dashboard.cards.removeAll { $0.id == id }
        } else if operation == "upsert_card" {
            let cardID: UUID
            if let raw = arguments["card_id"]?.stringValue {
                guard let id = UUID(uuidString: raw) else { throw IDEToolError.invalidArguments("Invalid card_id.") }
                cardID = id
            } else { cardID = UUID() }
            let index = dashboard.cards.firstIndex { $0.id == cardID }
            let integrationID = arguments["integration_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? index.map { dashboard.cards[$0].integrationID }
            guard let integrationID, dashboard.integrations.contains(where: { $0.id == integrationID }) else { throw IDEToolError.invalidArguments("A valid integration_id is required.") }
            var card = index.map { dashboard.cards[$0] } ?? .init(id: cardID, integrationID: integrationID)
            card.integrationID = integrationID
            if let style = arguments["style"]?.stringValue {
                guard UsageCardConfiguration.styles.contains(style) else { throw IDEToolError.invalidArguments("Unsupported card style.") }
                card.style = style
            }
            if let raw = arguments["metric_ids"] {
                guard let values = raw.arrayValue, values.allSatisfy({ $0.stringValue?.isEmpty == false }) else {
                    throw IDEToolError.invalidArguments("metric_ids must be an array of nonempty metric IDs; use [] for all metrics.")
                }
                card.selectMetrics(values.compactMap(\.stringValue))
            } else if let metric = arguments["metric_id"]?.stringValue {
                card.selectMetrics(metric.isEmpty ? [] : [metric])
            }
            if let visible = arguments["visible"]?.boolValue { card.isVisible = visible }
            if let menu = arguments["menu_bar"]?.boolValue { card.showInMenuBar = menu }
            if let widget = arguments["widget"]?.boolValue { card.showInWidget = widget }
            if let index { dashboard.cards[index] = card } else { dashboard.cards.append(card) }
        } else if operation != "get" { throw IDEToolError.invalidArguments("Unsupported operation.") }
        if operation != "get" {
            try await UsageDashboardStore.shared.save(dashboard, at: activeWorkspace.storageURL)
            usageDashboard = dashboard
            publishUsageDashboard()
        }
        return jsonTextResult(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(dashboard)))
    }
}
