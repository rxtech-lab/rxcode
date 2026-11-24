import CoreFoundation
import Foundation
import RxCodeExtensionSDK

typealias UsageMetric = ExtensionUsageSnapshot.Metric

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
    static func cloudflare(_ data: Data) throws -> [UsageMetric] {
        let root = try object(data)
        guard root["success"] as? Bool == true, let rows = root["result"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
        var totals: [String: (service: String, unit: String, value: Double)] = [:]
        var costs: [String: Double] = [:]
        for row in rows {
            guard let service = row["ServiceName"] as? String, !service.isEmpty,
                  let unit = row["ConsumedUnit"] as? String,
                  let value = number(row["ConsumedQuantity"]), value.isFinite else {
                throw ExtensionCallError.invalidRequest
            }
            // Keep each product and consumption unit separate; cumulative pricing
            // quantities and currency charges are not consumption observations.
            let key = "\(service)|\(unit)"
            let total = (totals[key]?.value ?? 0) + value
            guard total.isFinite else { throw ExtensionCallError.invalidRequest }
            totals[key] = (service, unit, total)
            // BilledCost is per charge period; CumulatedContractedCost is a running total and is never summed.
            if let cost = number(row["BilledCost"]), cost.isFinite,
               let currency = row["BillingCurrency"] as? String, !currency.isEmpty {
                costs[currency, default: 0] += cost
            }
        }
        let billed = costs.keys.sorted().map { currency in
            UsageMetric(id: "billable|\(currency)", title: "Billable usage", value: costs[currency]!, unit: currency,
                        detail: "Usage-based charges for the current billing period, updated daily by Cloudflare. Plan subscription fees are not included.")
        }
        if totals.isEmpty {
            return [.init(id: "account-consumption", title: "Account consumption", value: nil, unit: "",
                          detail: "Cloudflare returned no metered usage for the current billing period.")]
        }
        return billed + totals.keys.sorted().map { key in
            let total = totals[key]!
            return .init(id: key, title: total.service, value: total.value, unit: total.unit,
                         detail: "Metered consumption for the current billing period; not an invoice total.")
        }
    }

    static func cloudflareZone(_ data: Data) throws -> [UsageMetric] {
        let root = try object(data)
        guard root["success"] as? Bool == true, let result = root["result"] as? [String: Any],
              let totals = result["totals"] as? [String: Any] else { throw ExtensionCallError.invalidRequest }
        return try ["requests", "bandwidth"].map { key in
            guard let item = totals[key] as? [String: Any], let value = number(item["all"]) else { throw ExtensionCallError.invalidRequest }
            return .init(id: key, title: key.capitalized, value: value, unit: key == "bandwidth" ? "bytes" : "requests")
        }
    }
}
