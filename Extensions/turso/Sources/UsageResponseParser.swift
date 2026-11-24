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
    static func turso(_ data: Data, database: Bool) throws -> [UsageMetric] {
        let root = try object(data)
        let entity = root[database ? "database" : "organization"] as? [String: Any]
        guard let usage = entity?[database ? "total" : "usage"] as? [String: Any] else { throw ExtensionCallError.invalidRequest }
        return try ["rows_read", "rows_written", "storage_bytes", "bytes_synced"].map { key in
            guard let value = number(usage[key]) else { throw ExtensionCallError.invalidRequest }
            return .init(id: key, title: key.replacingOccurrences(of: "_", with: " "), value: value, unit: key.contains("bytes") ? "bytes" : "rows")
        }
    }
}
