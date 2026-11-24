import Foundation
import RxCodeExtensionSDK

extension VercelAccounts {
    static func choices(host: RxCodeHost) async throws -> [ExtensionUsageAccount] {
        let base = URL(string: "https://api.vercel.com")!
        let user = try await host.fetch(base.appending(path: "v2/user"), credentialSlot: "primary")
        // A team-scoped token may list teams without access to the user endpoint.
        let defaultTeam = (200..<300).contains(user.status) ? try? UsageResponseParser.vercelDefaultTeam(user.body) : nil
        var teams: [String: VercelAccount] = [:]
        var until: Int?
        var seen = Set<Int>()
        for _ in 1...10 {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let until { query.append(.init(name: "until", value: String(until))) }
            let url = base.appending(path: "v2/teams").appending(queryItems: query)
            let response = try await host.fetch(url, credentialSlot: "primary")
            let page = try UsageResponseParser.vercelTeams(VercelUsage.checkedBody(response))
            for team in page.teams where teams[team.id] == nil { teams[team.id] = team }
            guard let next = page.next else { break }
            guard let cursor = Int(exactly: next), seen.insert(cursor).inserted else { throw ExtensionCallError.invalidRequest }
            until = cursor
        }
        let sorted = teams.values.sorted {
            ($0.id != defaultTeam ? 1 : 0, $0.name.lowercased(), $0.id) < ($1.id != defaultTeam ? 1 : 0, $1.name.lowercased(), $1.id)
        }
        return [.init(id: "", name: String(localized: "Default team"))] + sorted.map {
            .init(id: $0.id, name: "\($0.name) (\($0.slug))")
        }
    }
}
