import Foundation
import CoreFoundation


/// Network work is isolated from UI actors. Each provider owns its response
/// interpretation; only normalized metrics cross the plugin boundary.
public actor CloudUsagePlugin: UsagePlugin {
    public nonisolated let descriptor: UsagePluginDescriptor
    private let session: URLSession
    private let cloudflareAnalyticsEndpoint: URL
    private let cloudflareAPIBase: URL
    private let vercelAPIBase: URL
    private let gatewayAPIBase: URL
    private let gatewayCredential: @Sendable (UUID) async -> String?
    private let billingCredential: @Sendable (UUID) async -> String?
    public init(id: String, session: URLSession = .shared,
                cloudflareAnalyticsEndpoint: URL = URL(string: "https://api.cloudflare.com/client/v4/graphql")!,
                cloudflareAPIBase: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
                vercelAPIBase: URL = URL(string: "https://api.vercel.com")!,
                gatewayAPIBase: URL = URL(string: "https://ai-gateway.vercel.sh")!,
                gatewayCredential: @escaping @Sendable (UUID) async -> String? = { _ in nil },
                billingCredential: @escaping @Sendable (UUID) async -> String? = { _ in nil }) {
        self.session = session
        self.cloudflareAnalyticsEndpoint = cloudflareAnalyticsEndpoint
        self.cloudflareAPIBase = cloudflareAPIBase
        self.vercelAPIBase = vercelAPIBase
        self.gatewayAPIBase = gatewayAPIBase
        self.gatewayCredential = gatewayCredential
        self.billingCredential = billingCredential
        let names = ["vercel": "Vercel", "neon": "Neon", "turso": "Turso", "cloudflare": "Cloudflare", "github-ci": "GitHub CI"]
        descriptor = .init(id: id, title: names[id] ?? id,
                           // Vercel OAuth is hidden until its billing scopes leave closed beta; it uses an access token.
                           authentication: id == "cloudflare" ? "OAuth" : "API key",
                           resourceLabel: id == "turso" ? "Database name (optional)" : "Project / resource ID (optional)")
    }
    public func fetch(configuration c: UsageIntegration, credential: String, now: Date) async throws -> UsagePluginSnapshot {
        // Vercel falls back to the signed-in user's default team when no account is chosen.
        guard !credential.isEmpty, !c.account.isEmpty || descriptor.id == "vercel" else { throw UsagePluginError.invalidConfiguration }
        let to = ISO8601DateFormatter().string(from: now)
        let from = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 86400))
        var metrics: [UsageMetric]
        var period = "Last 30 days"
        switch descriptor.id {
        case "vercel":
            // Billing charges are team-scoped; an unscoped request returns 404 "Costs not found",
            // so a blank account resolves to the token user's default team.
            var account = c.account
            if account.isEmpty {
                account = try UsageResponseParser.vercelDefaultTeam(await request(vercelAPIBase.appending(path: "v2/user").absoluteString, query: [:], token: credential)) ?? ""
            }
            metrics = try await vercelCharges(query: VercelAccounts.scope(account).merging(["from": from, "to": to]) { $1 },
                                              project: c.resource, token: credential)
            var credits = UsageMetric("ai-gateway-balance", "AI Gateway credits", value: nil, unit: "USD",
                                      detail: "Add an AI Gateway API key for this team in the integration sheet.")
            if let key = await gatewayCredential(c.id), !key.isEmpty {
                do {
                    let data = try await request(gatewayAPIBase.appending(path: "v1/credits").absoluteString, query: [:], token: key)
                    credits = try UsageResponseParser.vercelGatewayCredits(data)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    credits.detail = "Could not refresh AI Gateway credits. Check the team's AI Gateway API key."
                }
            }
            // Keep the account balance ahead of service breakdowns in every default card.
            let index = metrics.firstIndex { !$0.id.hasPrefix("billable|") } ?? metrics.endIndex
            metrics.insert(credits, at: index)
        case "turso":
            let base = "https://api.turso.tech/v1/organizations/\(try component(c.account))"
            let path = c.resource.isEmpty ? "/usage" : "/databases/\(try component(c.resource))/usage"
            let data = try await request(base + path, query: c.resource.isEmpty ? [:] : ["from": from, "to": to], token: credential)
            metrics = try UsageResponseParser.turso(data, database: !c.resource.isEmpty)
            if c.resource.isEmpty { period = "Current billing period" }
        case "neon":
            var totals: [String: Double] = [:]
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var query = ["org_id": c.account, "from": from, "to": to, "granularity": "daily", "limit": "100",
                             "metrics": "compute_unit_seconds,root_branch_bytes_month,public_network_transfer_bytes"]
                if !c.resource.isEmpty { query["project_ids"] = c.resource }
                query["cursor"] = cursor
                let data = try await request("https://console.neon.tech/api/v2/consumption_history/v2/projects", query: query, token: credential)
                let page = try UsageResponseParser.neon(data)
                for (key, value) in page.totals { totals[key, default: 0] += value }
                cursor = page.cursor
                if let cursor, (!seen.insert(cursor).inserted || seen.count > 100) { throw UsagePluginError.paginationLimit }
            } while cursor != nil
            metrics = totals.sorted { $0.key < $1.key }.map { .init($0.key, $0.key.replacingOccurrences(of: "_", with: " "), value: $0.value, unit: $0.key == "compute_unit_seconds" ? "CU seconds" : ($0.key == "root_branch_bytes_month" ? "byte-hours" : "bytes")) }
            period = "Last 30 days · daily granularity"
        case "cloudflare":
            let scope = CloudflareUsageScope(resource: c.resource)
            if scope == .worker || scope == .r2 {
                var request = try CloudflareResourceUsage.request(account: c.account, resource: c.resource,
                    now: now, endpoint: cloudflareAnalyticsEndpoint)
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                let data = try await send(request)
                metrics = try CloudflareResourceUsage.metrics(data, resource: c.resource)
                period = "Last 24 hours · analytics"
            } else if c.resource.isEmpty {
                // Cloudflare OAuth apps cannot request Billing Read; an optional API token supplies it.
                let billingToken = await billingCredential(c.id).flatMap { $0.isEmpty ? nil : $0 }
                let message = billingToken == nil ? Self.cloudflareBillingTokenMissingMessage : Self.cloudflareBillingTokenDeniedMessage
                do {
                    // Omitting dates asks Cloudflare for the current billing period.
                    let endpoint = cloudflareAPIBase.appendingPathComponent("accounts")
                        .appendingPathComponent(try component(c.account)).appendingPathComponent("billable-usage")
                    let data = try await request(endpoint.absoluteString, query: [:], token: billingToken ?? credential)
                    metrics = try UsageResponseParser.cloudflare(data)
                    period = "Current billing period"
                } catch UsagePluginError.provider(403, _) {
                    throw UsagePluginError.provider(403, message)
                } catch UsagePluginError.http(403) {
                    throw UsagePluginError.provider(403, message)
                }
            } else {
                let data = try await request("https://api.cloudflare.com/client/v4/zones/\(try component(c.resource))/analytics/dashboard",
                    query: ["since": from, "until": to], token: credential)
                metrics = try UsageResponseParser.cloudflareZone(data)
            }
        default: throw UsagePluginError.invalidConfiguration
        }
        return .init(id: c.id, pluginID: c.pluginID, title: c.title, projectID: c.projectID,
                     scope: scope(c), period: period, fetchedAt: now, metrics: metrics)
    }
    private func scope(_ c: UsageIntegration) -> String {
        let account = c.account.isEmpty ? "Default team" : c.account
        return c.resource.isEmpty ? account : "\(account) / \(c.resource)"
    }
    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw UsagePluginError.invalidConfiguration }
        return encoded
    }
    private static let cloudflareBillingTokenMissingMessage = "Cloudflare denied access to account billing usage. Cloudflare sign-in cannot grant Billing Read, so add a Cloudflare API token with Account > Billing > Read in the integration sheet, or use Worker script or R2 bucket analytics."
    private static let cloudflareBillingTokenDeniedMessage = "Cloudflare denied the billing API token access to account billing usage. Check that the token includes Account > Billing > Read for this account. The Billable Usage API is in alpha and may not be available to every account."
    private func request(_ base: String, query: [String: String], token: String) async throws -> Data {
        var url = URLComponents(string: base)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }
    /// Vercel streams one FOCUS row per service, SKU and day as JSONL; a busy team returns
    /// tens of megabytes for 30 days, so rows are summed while streaming instead of buffered.
    private func vercelCharges(query: [String: String], project: String, token: String) async throws -> [UsageMetric] {
        var url = URLComponents(url: vercelAPIBase.appending(path: "v1/billing/charges"), resolvingAgainstBaseURL: false)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64 * 1024 { break } }
            if let message = UsageResponseParser.errorMessage(body) { throw UsagePluginError.provider(http.statusCode, message) }
            throw UsagePluginError.http(http.statusCode)
        }
        var totals = UsageResponseParser.VercelTotals(project: project)
        for try await line in bytes.lines { try totals.add(line) }
        return totals.metrics
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let message = UsageResponseParser.errorMessage(data) { throw UsagePluginError.provider(http.statusCode, message) }
            throw UsagePluginError.http(http.statusCode)
        }
        guard data.count <= 32 * 1024 * 1024 else { throw UsagePluginError.invalidResponse }
        return data
    }
}

/// A Vercel team or personal scope the signed-in user can bill against.
public struct VercelAccount: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let slug: String
    public init(id: String, name: String, slug: String) { self.id = id; self.name = name; self.slug = slug }
}

public enum VercelAccounts {
    /// Team IDs (`team_…`) are sent as `teamId`; anything else is treated as a team slug.
    /// An empty account omits both so Vercel uses the token's default scope.
    public static func scope(_ account: String) -> [String: String] {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.isEmpty { return [:] }
        return account.hasPrefix("team_") ? ["teamId": account] : ["slug": account]
    }

    /// Lists the teams the token's user belongs to, default team first.
    public static func list(token: String, session: URLSession = .shared) async throws -> [VercelAccount] {
        func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
            var url = URLComponents(string: "https://api.vercel.com" + path)!
            if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                if let message = UsageResponseParser.errorMessage(data) { throw UsagePluginError.provider(http.statusCode, message) }
                throw UsagePluginError.http(http.statusCode)
            }
            return data
        }
        // Only used for ordering; tokens without user access can still list teams.
        let defaultTeam = try? UsageResponseParser.vercelDefaultTeam(await get("/v2/user"))
        var teams: [VercelAccount] = []
        var until: String?
        var pages = 0
        repeat {
            var query = ["limit": "100"]
            query["until"] = until
            let page = try UsageResponseParser.vercelTeams(await get("/v2/teams", query))
            teams += page.teams.filter { team in !teams.contains { $0.id == team.id } }
            pages += 1
            until = page.next.map { String(Int($0)) }
        } while until != nil && pages < 10
        return teams.sorted { ($0.id == defaultTeam ? 0 : 1, $0.name.lowercased()) < ($1.id == defaultTeam ? 0 : 1, $1.name.lowercased()) }
    }
}

public enum UsageResponseParser {
    /// Extracts a human-readable provider error (Vercel `error.message`, Cloudflare `errors[].message`).
    public static func errorMessage(_ data: Data) -> String? {
        guard let root = try? object(data) else { return nil }
        let message = ((root["error"] as? [String: Any])?["message"] as? String)
            ?? (root["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String }.joined(separator: "; ")
            ?? root["message"] as? String
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
    }
    public static func vercelDefaultTeam(_ data: Data) throws -> String? {
        guard let user = try object(data)["user"] as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return user["defaultTeamId"] as? String
    }
    public static func vercelTeams(_ data: Data) throws -> (teams: [VercelAccount], next: Double?) {
        let root = try object(data)
        guard let teams = root["teams"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
        let accounts = teams.compactMap { team -> VercelAccount? in
            guard let id = team["id"] as? String, let slug = team["slug"] as? String else { return nil }
            let name = (team["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
            return .init(id: id, name: name, slug: slug)
        }
        return (accounts, number((root["pagination"] as? [String: Any])?["next"]))
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return object
    }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String, let value = Double(text), value.isFinite { return value }
        return nil
    }
    public static func vercel(_ data: Data, project: String) throws -> [UsageMetric] {
        guard let text = String(data: data, encoding: .utf8) else { throw UsagePluginError.invalidResponse }
        var totals = VercelTotals(project: project)
        for line in text.split(whereSeparator: \.isNewline) { try totals.add(String(line)) }
        return totals.metrics
    }
    public static func vercelGatewayCredits(_ data: Data) throws -> UsageMetric {
        let row = try object(data)
        guard let balance = number(row["balance"]), balance >= 0,
              let used = number(row["total_used"]), used >= 0 else { throw UsagePluginError.invalidResponse }
        return .init("ai-gateway-balance", "AI Gateway credits", value: balance, unit: "USD",
                     detail: "Remaining team balance · \(used.formatted(.currency(code: "USD"))) used to date. Not filtered by project.")
    }
    /// Sums Vercel FOCUS JSONL rows into billed cost per currency and service.
    public struct VercelTotals {
        let project: String
        private var totals: [String: Double] = [:]
        private var billed: [String: Double] = [:]
        public init(project: String) { self.project = project }
        public mutating func add(_ line: String) throws {
            guard !line.allSatisfy(\.isWhitespace) else { return }
            let row = try object(Data(line.utf8))
            guard let amount = number(row["BilledCost"]), let currency = row["BillingCurrency"] as? String,
                  let service = row["ServiceName"] as? String else { throw UsagePluginError.invalidResponse }
            if !project.isEmpty {
                let tags = row["Tags"] as? [String: Any]
                guard tags?["ProjectId"] as? String == project else { return }
            }
            totals["\(currency)|\(service)", default: 0] += amount
            billed[currency, default: 0] += amount
        }
        public var metrics: [UsageMetric] {
            guard !billed.isEmpty else {
                return [.init("billable|unavailable", "Billable usage", value: nil, unit: "",
                              detail: "No billing charge rows returned for this scope and period.")]
            }
            let headline: [UsageMetric] = billed.sorted { $0.key < $1.key }.map {
                .init("billable|\($0.key)", "Billable usage", value: $0.value, unit: $0.key,
                      detail: "Billed charges over the last 30 days. Included credit and billing-cycle totals are not provided by this view.")
            }
            return headline + totals.sorted { $0.key < $1.key }.map {
                let parts = $0.key.split(separator: "|", maxSplits: 1)
                return .init($0.key, String(parts[1]), value: $0.value, unit: String(parts[0]))
            }
        }
    }
    public static func turso(_ data: Data, database: Bool) throws -> [UsageMetric] {
        let root = try object(data)
        let entity = root[database ? "database" : "organization"] as? [String: Any]
        guard let usage = entity?[database ? "total" : "usage"] as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return try ["rows_read", "rows_written", "storage_bytes", "bytes_synced"].map { key in
            guard let value = number(usage[key]) else { throw UsagePluginError.invalidResponse }
            return .init(key, key.replacingOccurrences(of: "_", with: " "), value: value, unit: key.contains("bytes") ? "bytes" : "rows")
        }
    }
    public static func neon(_ data: Data) throws -> (totals: [String: Double], cursor: String?) {
        let root = try object(data)
        guard let projects = root["projects"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
        var totals: [String: Double] = [:]
        for project in projects {
            guard let periods = project["periods"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
            for period in periods {
                guard let consumption = period["consumption"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
                for window in consumption {
                    guard let metrics = window["metrics"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
                    for metric in metrics {
                        guard let key = metric["metric_name"] as? String, let value = number(metric["value"]) else { throw UsagePluginError.invalidResponse }
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
    public static func cloudflare(_ data: Data) throws -> [UsageMetric] {
        let root = try object(data)
        guard root["success"] as? Bool == true, let rows = root["result"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
        var totals: [String: (service: String, unit: String, value: Double)] = [:]
        var costs: [String: Double] = [:]
        for row in rows {
            guard let service = row["ServiceName"] as? String, !service.isEmpty,
                  let unit = row["ConsumedUnit"] as? String,
                  let value = number(row["ConsumedQuantity"]), value.isFinite else {
                throw UsagePluginError.invalidResponse
            }
            // Keep each product and consumption unit separate; cumulative pricing
            // quantities and currency charges are not consumption observations.
            let key = "\(service)|\(unit)"
            let total = (totals[key]?.value ?? 0) + value
            guard total.isFinite else { throw UsagePluginError.invalidResponse }
            totals[key] = (service, unit, total)
            // BilledCost is per charge period; CumulatedContractedCost is a running total and is never summed.
            if let cost = number(row["BilledCost"]), cost.isFinite,
               let currency = row["BillingCurrency"] as? String, !currency.isEmpty {
                costs[currency, default: 0] += cost
            }
        }
        let billed = costs.keys.sorted().map { currency in
            UsageMetric("billable|\(currency)", "Billable usage", value: costs[currency]!, unit: currency,
                        detail: "Usage-based charges for the current billing period, updated daily by Cloudflare. Plan subscription fees are not included.")
        }
        if totals.isEmpty {
            return [.init("account-consumption", "Account consumption", value: nil, unit: "",
                          detail: "Cloudflare returned no metered usage for the current billing period.")]
        }
        return billed + totals.keys.sorted().map { key in
            let total = totals[key]!
            return .init(key, total.service, value: total.value, unit: total.unit,
                         detail: "Metered consumption for the current billing period; not an invoice total.")
        }
    }

    public static func cloudflareZone(_ data: Data) throws -> [UsageMetric] {
        let root = try object(data)
        guard root["success"] as? Bool == true, let result = root["result"] as? [String: Any],
              let totals = result["totals"] as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return try ["requests", "bandwidth"].map { key in
            guard let item = totals[key] as? [String: Any], let value = number(item["all"]) else { throw UsagePluginError.invalidResponse }
            return .init(key, key.capitalized, value: value, unit: key == "bandwidth" ? "bytes" : "requests")
        }
    }
}
