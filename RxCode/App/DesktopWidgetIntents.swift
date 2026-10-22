import AppIntents
import Foundation
import RxCodeCore

// Compile into both the app and widget so macOS can resolve configuration metadata
// using the containing app identity as well as the widget extension identity.
struct WidgetProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static var defaultQuery = WidgetProjectQuery()
    static let all = Self(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "All Projects")
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WidgetProjectQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetProjectEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func defaultResult() async -> WidgetProjectEntity? { .all }

    func suggestedEntities() async throws -> [WidgetProjectEntity] {
        [WidgetProjectEntity.all] + DesktopWidgetStore.load().projects.map { WidgetProjectEntity(id: $0.id, name: $0.name) }
    }
}

struct ProjectWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Project Tasks"
    static var description = IntentDescription("Choose a project from the workspace most recently used in RxCode.")
    @Parameter(title: "Project") var project: WidgetProjectEntity?

    init() { project = .all }
}

struct WidgetAgentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static var defaultQuery = WidgetAgentQuery()
    static let all = Self(id: "all", name: "All Agents")
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct WidgetAgentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetAgentEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func defaultResult() async -> WidgetAgentEntity? { .all }

    func suggestedEntities() async throws -> [WidgetAgentEntity] {
        [WidgetAgentEntity.all] + DesktopWidgetStore.load().agents.map { WidgetAgentEntity(id: $0.id, name: $0.name) }
    }
}
struct AgentWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Agent Usage"
    @Parameter(title: "Agent") var agent: WidgetAgentEntity?

    init() { agent = .all }
}

