import CoreFoundation
import Foundation
import RxCodeExtensionSDK

typealias UsageMetric = ExtensionUsageSnapshot.Metric

/// A Vercel team or personal scope the signed-in user can bill against.
struct VercelAccount: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let slug: String
    init(id: String, name: String, slug: String) { self.id = id; self.name = name; self.slug = slug }
}

enum VercelAccounts {
    /// Team IDs (`team_…`) are sent as `teamId`; anything else is treated as a team slug.
    /// An empty account omits both so Vercel uses the token's default scope.
    static func scope(_ account: String) -> [String: String] {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.isEmpty { return [:] }
        return account.hasPrefix("team_") ? ["teamId": account] : ["slug": account]
    }
}

enum UsageResponseParser {
    /// Extracts a human-readable provider error (Vercel `error.message`, Cloudflare `errors[].message`).
    static func errorMessage(_ data: Data) -> String? {
        guard let root = try? object(data) else { return nil }
        let message = ((root["error"] as? [String: Any])?["message"] as? String)
            ?? (root["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String }.joined(separator: "; ")
            ?? root["message"] as? String
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ExtensionCallError.invalidRequest }
        return object
    }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String, let value = Double(text), value.isFinite { return value }
        return nil
    }
    static func vercelDefaultTeam(_ data: Data) throws -> String? {
        guard let user = try object(data)["user"] as? [String: Any] else { throw ExtensionCallError.invalidRequest }
        return user["defaultTeamId"] as? String
    }
    static func vercelTeams(_ data: Data) throws -> (teams: [VercelAccount], next: Double?) {
        let root = try object(data)
        guard let teams = root["teams"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
        let accounts = teams.compactMap { team -> VercelAccount? in
            guard let id = team["id"] as? String, let slug = team["slug"] as? String else { return nil }
            let name = (team["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
            return .init(id: id, name: name, slug: slug)
        }
        return (accounts, number((root["pagination"] as? [String: Any])?["next"]))
    }
    static func vercel(_ data: Data, project: String) throws -> [UsageMetric] {
        guard let text = String(data: data, encoding: .utf8) else { throw ExtensionCallError.invalidRequest }
        var totals = VercelTotals(project: project)
        for line in text.split(whereSeparator: \.isNewline) { try totals.add(String(line)) }
        return totals.metrics
    }
    static func vercelGatewayCredits(_ data: Data) throws -> UsageMetric {
        let row = try object(data)
        guard let balance = number(row["balance"]), balance >= 0,
              let used = number(row["total_used"]), used >= 0 else { throw ExtensionCallError.invalidRequest }
        return .init(id: "ai-gateway-balance", title: "AI Gateway credits", value: balance, unit: "USD",
                     detail: "Remaining team balance · \(used.formatted(.currency(code: "USD"))) used to date. Not filtered by project.")
    }
    /// Sums Vercel FOCUS JSONL rows into billed cost per currency and service.
    struct VercelTotals {
        let project: String
        private var totals: [String: Double] = [:]
        private var billed: [String: Double] = [:]
        init(project: String) { self.project = project }
        mutating func add(_ line: String) throws {
            guard !line.allSatisfy(\.isWhitespace) else { return }
            let row = try object(Data(line.utf8))
            guard let amount = number(row["BilledCost"]), let currency = row["BillingCurrency"] as? String,
                  !currency.isEmpty, !currency.contains("|"), let service = row["ServiceName"] as? String, !service.isEmpty else { throw ExtensionCallError.invalidRequest }
            if !project.isEmpty {
                let tags = row["Tags"] as? [String: Any]
                guard tags?["ProjectId"] as? String == project else { return }
            }
            totals["\(currency)|\(service)", default: 0] += amount
            billed[currency, default: 0] += amount
        }
        var metrics: [UsageMetric] {
            guard !billed.isEmpty else {
                return [.init(id: "billable|unavailable", title: "Billable usage", value: nil, unit: "",
                              detail: "No billing charge rows returned for this scope and period.")]
            }
            let headline: [UsageMetric] = billed.sorted { $0.key < $1.key }.map {
                .init(id: "billable|\($0.key)", title: "Billable usage", value: $0.value, unit: $0.key,
                      detail: "Billed charges over the last 30 days. Included credit and billing-cycle totals are not provided by this view.")
            }
            return headline + totals.sorted { $0.key < $1.key }.map {
                let parts = $0.key.split(separator: "|", maxSplits: 1)
                return .init(id: $0.key, title: String(parts[1]), value: $0.value, unit: String(parts[0]))
            }
        }
    }
}
