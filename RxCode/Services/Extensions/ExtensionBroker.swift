import Foundation
import RxCodeCore
import RxCodeExtensionSDK

/// A connection's authority is captured by the host. Request payloads cannot select a workspace,
/// another contributor's storage, a provider integration, or the origin of a permission prompt.
@MainActor
final class ExtensionBroker {
    private let manifest: ExtensionManifest
    private let identity: String
    private let projectRoot: URL
    private let sceneBrokers = NSHashTable<ExtensionBroker>.weakObjects()
    private let files: ExtensionFileAccess
    private weak var appState: AppState?
    private let project: Project?
    private let integration: UsageIntegration?
    typealias NetworkFetch = @Sendable (URLRequest, Set<String>) async throws -> ExtensionNetworkResponse
    private let fetch: NetworkFetch
    private let verifiedProvider: Bool
    private var blocked = false
    private struct Call {
        let worker: Task<Void, Never>
        let complete: (ExtensionCallError) -> Void
    }
    private var calls: [UUID: Call] = [:]
    private static var recent: [String: [ContinuousClock.Instant]] = [:]
    private static var concurrent: [String: Int] = [:]
    typealias Origin = ExtensionPermissionDecisions.Origin

    init(manifest: ExtensionManifest, projectRoot: URL, bundleIdentifier: String,
         appState: AppState? = nil, project: Project? = nil, integration: UsageIntegration? = nil, verifiedProvider: Bool = false,
         fetch: @escaping NetworkFetch = ExtensionNetworkResponse.fetch) throws {
        try manifest.validate()
        self.projectRoot = projectRoot
        self.manifest = manifest
        identity = bundleIdentifier
        files = try ExtensionFileAccess(projectRoot: projectRoot)
        self.appState = appState
        self.project = project
        self.integration = integration
        self.fetch = fetch
        self.verifiedProvider = verifiedProvider
    }

    func bindUsageScene(to integration: UsageIntegration, appState: AppState) throws -> ExtensionBroker {
        guard !blocked,
              manifest.contributes.usageProviders?.contains(where: { $0.pluginID == integration.pluginID }) == true,
              integration.projectID == nil || integration.projectID == project?.id,
              appState.usageDashboard.integrations.contains(integration) else { throw ExtensionCallError.permissionDenied }
        let child = try ExtensionBroker(manifest: manifest, projectRoot: projectRoot, bundleIdentifier: identity,
                                        appState: appState, project: project, integration: integration,
                                        verifiedProvider: verifiedProvider && manifest.id == "app.rxlab.extensions." + integration.pluginID)
        sceneBrokers.add(child)
        return child
    }

    func block() {
        blocked = true
        for child in sceneBrokers.allObjects { child.block() }
        sceneBrokers.removeAllObjects()
        for call in calls.values {
            call.worker.cancel()
            call.complete(.extensionBlocked)
        }
    }

    func handle(_ request: ExtensionRequest, origin: Origin = .background, permissionsReviewed: Bool = false) async -> ExtensionResponse {
        guard !blocked else { return ExtensionResponse(replyingTo: request, error: .extensionBlocked) }
        let cutoff = ContinuousClock.now - .seconds(60)
        Self.recent[identity, default: []].removeAll { $0 <= cutoff }
        guard (Self.recent[identity]?.count ?? 0) < 120, Self.concurrent[identity, default: 0] < 4,
              calls[request.id] == nil, request.payload.count <= 2 * 1024 * 1024 else {
            return ExtensionResponse(replyingTo: request, error: .invalidRequest)
        }
        Self.recent[identity, default: []].append(.now)
        Self.concurrent[identity, default: 0] += 1
        let (stream, continuation) = AsyncStream<ExtensionResponse>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let fail: (ExtensionCallError) -> Void = { error in
            continuation.yield(ExtensionResponse(replyingTo: request, error: error))
            continuation.finish()
        }
        let worker = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let response = try await dispatch(request, origin: origin, permissionOrigin: permissionsReviewed ? .background : origin)
                try Task.checkCancellation()
                continuation.yield(response)
                continuation.finish()
            } catch let error as ExtensionCallError { fail(error) }
            catch let error as URLError where error.code == .timedOut { fail(.timeout) }
            catch { fail(blocked ? .extensionBlocked : .invalidRequest) }
        }
        calls[request.id] = Call(worker: worker, complete: fail)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            fail(.timeout)
            worker.cancel()
        }
        defer {
            worker.cancel()
            timeout.cancel()
            calls.removeValue(forKey: request.id)
            Self.concurrent[identity, default: 1] -= 1
        }
        var iterator = stream.makeAsyncIterator()
        let response = await iterator.next()
        if blocked { return ExtensionResponse(replyingTo: request, error: .extensionBlocked) }
        return response ?? ExtensionResponse(replyingTo: request, error: .invalidRequest)
    }

    private func allow(_ permission: ExtensionPermission.ID, _ origin: Origin) async throws {
        try Task.checkCancellation()
        let access = try await ExtensionPermissionStore.shared.authorize(permission, manifest: manifest,
                                                                         identity: identity, origin: origin)
        try Task.checkCancellation()
        guard !blocked else { throw ExtensionCallError.extensionBlocked }
        switch access {
        case .granted: return
        case .needsPrompt, .permissionPending: throw ExtensionCallError.permissionPending
        case .permissionDenied: throw ExtensionCallError.permissionDenied
        }
    }

    private func dispatch(_ request: ExtensionRequest, origin: Origin, permissionOrigin: Origin) async throws -> ExtensionResponse {
        switch request.operation {
        case .filesRead, .filesList:
            try await allow(.projectRead, permissionOrigin)
            let path = try request.decode([String: String].self)["path"]
            guard let path else { throw ExtensionCallError.invalidRequest }
            do { return try await fileResponse(request, path: path, unrestricted: false) }
            catch ExtensionFileAccess.Failure.denied {}
            catch ExtensionFileAccess.Failure.invalidPath where path.hasPrefix("/") {}
            try await allow(.diskRead, permissionOrigin)
            return try await fileResponse(request, path: path, unrestricted: true)
        case .storageGet, .storageSet:
            try await allow(.storage, permissionOrigin)
            let input = try request.decode([String: JSONValue].self)
            guard let key = input["key"]?.stringValue, request.operation != .storageSet || input["value"] != nil else {
                throw ExtensionCallError.invalidRequest
            }
            let value = try await ExtensionBrokerStorage.shared.value(identity: identity, key: key,
                                                                        set: request.operation == .storageSet ? input["value"] : nil)
            return try ExtensionResponse(replyingTo: request, value: value)
        case .contactsQuery:
            try await allow(.contactsRead, permissionOrigin)
            guard let name = try request.decode([String: String].self)["name"] else { throw ExtensionCallError.invalidRequest }
            let contacts = try await ExtensionBrokerStorage.shared.contacts(named: name, userInitiated: origin == .userInitiated)
            return try ExtensionResponse(replyingTo: request, value: contacts)
        case .netFetch:
            return try await network(request, origin: permissionOrigin)
        case .vaultRead, .vaultCreate:
            try await allow(request.operation == .vaultRead ? .vaultRead : .vaultCreate, permissionOrigin)
            guard origin == .userInitiated else { throw ExtensionCallError.permissionPending }
            return try await vault(request)
        case .localUsage, .rateLimits:
            try await allow(.usageLocalRead, permissionOrigin)
            return try localReport(request)
        default: throw ExtensionCallError.invalidRequest
        }
    }

    private func fileResponse(_ request: ExtensionRequest, path: String, unrestricted: Bool) async throws -> ExtensionResponse {
        try await Task.detached(priority: .utility) { [files] in
            if request.operation == .filesRead {
                return try ExtensionResponse(replyingTo: request, value: files.read(path, diskReadGranted: unrestricted))
            }
            return try ExtensionResponse(replyingTo: request, value: files.list(path, diskReadGranted: unrestricted))
        }.value
    }

    private func network(_ request: ExtensionRequest, origin: Origin) async throws -> ExtensionResponse {
        try await allow(.network, origin)
        let input = try request.decode(ExtensionNetworkRequest.self)
        let domains = Set(manifest.permissions.first { $0.id == .network }?.domains ?? [])
        var outbound = try input.request(domains: domains)
        if let slot = input.credentialSlot {
            let acp = slot.hasPrefix("acp:")
            let permission: ExtensionPermission.ID = acp ? .acpCredentialsUse : .credentialsUse
            try await allow(permission, origin)
            guard verifiedProvider, let slots = manifest.permissions.first(where: { $0.id == permission })?.slots,
                  let integration, manifest.contributes.usageProviders?.contains(where: { $0.pluginID == integration.pluginID }) == true,
                  appState?.usageDashboard.integrations.contains(integration) == true else { throw ExtensionCallError.permissionDenied }
            if acp {
                guard slot == "acp:" + integration.resource,
                      let client = appState?.acpClients.first(where: { $0.id == integration.resource && $0.enabled }),
                      let provider = ACPUsageProvider.provider(for: client), provider.pluginID == integration.pluginID,
                      slots.contains(slot) || slots.contains("acp:" + provider.rawValue) else {
                    throw ExtensionCallError.permissionDenied
                }
                outbound = try await ACPUsageService.shared.authorizedExtensionRequest(outbound, client: client, integration: integration, domains: domains)
            } else {
                guard slots.contains(slot) else { throw ExtensionCallError.permissionDenied }
                if slot == "oauth" {
                    let host = input.url.host?.lowercased()
                    guard (integration.pluginID == "cloudflare" && host == "api.cloudflare.com")
                            || (integration.pluginID == "vercel" && host == "api.vercel.com") else {
                        throw ExtensionCallError.permissionDenied
                    }
                    let base = outbound
                    let response = try await UsageOAuthTokens.shared.withAccessToken(integration) { [fetch] token in
                        guard let token, !token.isEmpty else { throw ExtensionCallError.credentialUnavailable }
                        try Task.checkCancellation()
                        var authenticated = base
                        authenticated.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                        let result = try await fetch(authenticated, domains)
                        if result.status == 401 { throw UsagePluginError.http(401) }
                        return result
                    }
                    return try ExtensionResponse(replyingTo: request, value: response)
                }
                let token = try await token(for: integration, slot: slot, host: input.url.host?.lowercased())
                outbound.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        try Task.checkCancellation()
        let response = try await fetch(outbound, domains)
        if response.status == 401, let integration, integration.pluginID == "acp-antigravity", input.credentialSlot != nil {
            await ACPUsageService.shared.invalidateExtensionSession(clientID: integration.resource, request: outbound)
        }
        return try ExtensionResponse(replyingTo: request, value: response)
    }

    private func token(for integration: UsageIntegration, slot: String, host: String?) async throws -> String {
        let value: String?
        let store = UsageDashboardStore.shared
        switch (integration.pluginID, slot, host) {
        case ("vercel", "gateway", "ai-gateway.vercel.sh"): value = await store.gatewayCredential(for: integration.id)
        case ("cloudflare", "billing", "api.cloudflare.com"): value = await store.billingCredential(for: integration.id)
        case ("vercel", "primary", "api.vercel.com"), ("cloudflare", "primary", "api.cloudflare.com"),
             ("github-ci", "primary", "api.github.com"), ("neon", "primary", "console.neon.tech"),
             ("turso", "primary", "api.turso.tech"):
            value = await store.credential(for: integration.id)
        default: throw ExtensionCallError.permissionDenied
        }
        guard let value, !value.isEmpty else { throw ExtensionCallError.credentialUnavailable }
        return value
    }

    private func localReport(_ request: ExtensionRequest) throws -> ExtensionResponse {
        let input = try request.decode([String: String].self)
        guard let appState, let range = UsageStatsRange(rawValue: input["range"] ?? "week") else {
            throw ExtensionCallError.invalidRequest
        }
        if request.operation == .localUsage {
            let projectIDs = integration.map(\.projectID) ?? project?.id
            let summary = appState.usageSummary(range: range, projectIds: projectIDs.map { Set([$0]) } ?? [])
            let modelLabels = Dictionary(uniqueKeysWithValues: summary.models.map {
                ($0.id, appState.usageModelDisplayName($0.model, provider: AgentProvider(rawValue: $0.providerRaw) ?? .acp))
            })
            let providerLabels = Dictionary(uniqueKeysWithValues: summary.providers.map {
                ($0.providerRaw, AgentProvider(rawValue: $0.providerRaw)?.displayNameText ?? $0.providerRaw)
            })
            return try ExtensionResponse(replyingTo: request, value: LocalUsageSummaryDTO(
                range: range, summary: summary, modelLabels: modelLabels, providerLabels: providerLabels))
        }
        let reports = AppState.rateLimitedProviders.map { provider in
            var costs = appState.rateLimitTaskCostSummary(for: provider, range: range)
            if let forecast = appState.rateLimitProviderStats[provider]?.weeklyForecast { costs.weeklyForecast = forecast }
            return RateLimitReportDTO(provider: provider, range: range, current: appState.cachedRateLimitUsage(for: provider),
                                      history: appState.rateLimitSamples(for: provider, range: range), costs: costs,
                                      measuredAt: appState.core.accountRateLimits[provider]?.measuredAt)
        }
        return try ExtensionResponse(replyingTo: request, value: reports)
    }

    private func vault(_ request: ExtensionRequest) async throws -> ExtensionResponse {
        let input = try request.decode([String: String].self)
        guard let appState, let project, let repo = project.gitHubRepo, !repo.isEmpty,
              let environment = input["environment"], !environment.isEmpty else { throw ExtensionCallError.invalidRequest }
        if request.operation == .vaultCreate && input["filename"] == nil {
            try await appState.createSecretEnvironment(repo: repo, name: environment)
            return try ExtensionResponse(replyingTo: request, value: true)
        }
        guard let filename = input["filename"], !filename.isEmpty, !filename.contains("/") else { throw ExtensionCallError.invalidRequest }
        let environments = try await appState.secrets.listEnvironments(repo: repo)
        guard let selected = environments.items.first(where: { $0.id == environment || $0.name == environment }) else {
            throw ExtensionCallError.invalidRequest
        }
        let bundle = try await appState.secrets.bundle(repo: repo, env: selected.id)
        try Task.checkCancellation()
        if request.operation == .vaultRead {
            guard let file = bundle.files.first(where: { $0.filename == filename }) else { throw ExtensionCallError.invalidRequest }
            let text = try await appState.decryptSecretFile(envKey: bundle.environmentKey, ciphertext: file.ciphertext, iv: file.iv)
            return try ExtensionResponse(replyingTo: request, value: text)
        }
        guard let content = input["content"], !bundle.files.contains(where: { $0.filename == filename }) else {
            throw ExtensionCallError.invalidRequest
        }
        let encrypted = try await appState.encryptSecretFile(forEnvironmentKey: bundle.environmentKey, filename: filename, content: content)
        try Task.checkCancellation()
        let created = try await appState.secrets.createFile(repo: repo, envId: selected.id, body: encrypted)
        return try ExtensionResponse(replyingTo: request, value: created)
    }
}
