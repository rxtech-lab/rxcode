import Foundation
import SwiftUI

/// Registration is explicit: plugins execute native code, never downloaded code
/// or scripts from a synced dashboard. Unknown IDs are unavailable, not executed.
public actor UsagePluginRegistry {
    private var plugins: [String: any UsagePlugin] = [:]
    public init() {}
    public func register(_ plugin: any UsagePlugin) { plugins[plugin.descriptor.id] = plugin }
    public func plugin(id: String) -> (any UsagePlugin)? { plugins[id] }
    public func descriptors() -> [UsagePluginDescriptor] { plugins.values.map(\.descriptor).sorted { $0.id < $1.id } }
    public func fetch(_ configuration: UsageIntegration, credential: String, now: Date = .now) async throws -> UsagePluginSnapshot {
        guard let plugin = plugins[configuration.pluginID] else { throw UsagePluginError.invalidConfiguration }
        return try await plugin.fetch(configuration: configuration, credential: credential, now: now)
    }
}

/// Adapts existing local collectors without giving them access to credentials.
public struct LocalUsagePlugin: UsagePlugin {
    public let descriptor: UsagePluginDescriptor
    private let collect: @Sendable (UsageIntegration) async throws -> UsagePluginSnapshot
    private let details: (@MainActor @Sendable (UsagePluginSnapshot, UsageCardConfiguration) -> AnyView)?
    public init(id: String, title: String,
                details: (@MainActor @Sendable (UsagePluginSnapshot, UsageCardConfiguration) -> AnyView)? = nil,
                collect: @escaping @Sendable (UsageIntegration) async throws -> UsagePluginSnapshot) {
        descriptor = .init(id: id, title: title, authentication: "Local", resourceLabel: "Project")
        self.collect = collect
        self.details = details
    }
    public func fetch(configuration: UsageIntegration, credential: String, now: Date) async throws -> UsagePluginSnapshot {
        try await collect(configuration)
    }
    @MainActor public func detailView(snapshot: UsagePluginSnapshot, configuration: UsageCardConfiguration) -> AnyView {
        details?(snapshot, configuration) ?? AnyView(UsagePluginDetailView(snapshot: snapshot, configuration: configuration))
    }
}
