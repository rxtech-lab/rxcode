import CoreFoundation
import Foundation
import RxCodeExtensionSDK

typealias UsageMetric = ExtensionUsageSnapshot.Metric

enum UsageResponseParser {
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ExtensionCallError.invalidRequest }
        return object
    }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String, let value = Double(text), value.isFinite { return value }
        return nil
    }
    static func neon(_ data: Data) throws -> (totals: [String: Double], cursor: String?) {
        let root = try object(data)
        guard let projects = root["projects"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
        var totals: [String: Double] = [:]
        for project in projects {
            guard let periods = project["periods"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
            for period in periods {
                guard let consumption = period["consumption"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
                for window in consumption {
                    guard let metrics = window["metrics"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
                    for metric in metrics {
                        guard let key = metric["metric_name"] as? String, let value = number(metric["value"]) else { throw ExtensionCallError.invalidRequest }
                        if ["compute_unit_seconds", "root_branch_bytes_month", "public_network_transfer_bytes"].contains(key) {
                            totals[key, default: 0] += value
                        }
                    }
                }
            }
        }
        let cursor = (root["pagination"] as? [String: Any])?["cursor"] as? String
        return (totals, cursor.flatMap { $0.isEmpty ? nil : $0 })
    }
}
