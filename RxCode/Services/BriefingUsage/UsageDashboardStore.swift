import Foundation
import RxCodeCore

actor UsageDashboardStore {
    static let shared = UsageDashboardStore()
    func load(at directory: URL) throws -> UsageDashboard? {
        let url = directory.appending(path: "usage-dashboard.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dashboard = try JSONDecoder().decode(UsageDashboard.self, from: Data(contentsOf: url))
        guard dashboard.version == 1 else { throw UsagePluginError.invalidResponse }
        return dashboard
    }
    func save(_ dashboard: UsageDashboard, at directory: URL) throws {
        let url = directory.appending(path: "usage-dashboard.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(dashboard).write(to: url, options: .atomic)
    }
    func credential(for id: UUID) -> String? {
        KeychainHelper.readString(service: "com.rxlab.RxCode.usage", account: id.uuidString)
    }
    func saveCredential(_ value: String, id: UUID) throws {
        try KeychainHelper.save(Data(value.utf8), service: "com.rxlab.RxCode.usage", account: id.uuidString)
    }
    func deleteCredential(id: UUID) throws {
        try KeychainHelper.delete(service: "com.rxlab.RxCode.usage", account: id.uuidString)
        try KeychainHelper.delete(service: "com.rxlab.RxCode.usage.gateway", account: id.uuidString)
        try KeychainHelper.delete(service: "com.rxlab.RxCode.usage.billing", account: id.uuidString)
    }
    func gatewayCredential(for id: UUID) -> String? {
        KeychainHelper.readString(service: "com.rxlab.RxCode.usage.gateway", account: id.uuidString)
    }
    func saveGatewayCredential(_ value: String, id: UUID) throws {
        try KeychainHelper.save(Data(value.utf8), service: "com.rxlab.RxCode.usage.gateway", account: id.uuidString)
    }
    /// Cloudflare OAuth apps cannot request Billing Read, so account billing usage uses a separate API token.
    func billingCredential(for id: UUID) -> String? {
        KeychainHelper.readString(service: "com.rxlab.RxCode.usage.billing", account: id.uuidString)
    }
    func saveBillingCredential(_ value: String, id: UUID) throws {
        try KeychainHelper.save(Data(value.utf8), service: "com.rxlab.RxCode.usage.billing", account: id.uuidString)
    }
}
