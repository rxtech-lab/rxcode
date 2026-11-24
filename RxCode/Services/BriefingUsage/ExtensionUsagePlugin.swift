import Foundation
import os
import RxCodeCore
import RxCodeExtensionBuild
import RxCodeExtensionDistribution
import RxCodeExtensionSDK
import SwiftUI

nonisolated enum UsageExtensionStatus: String, LocalizedError, Identifiable {
    case install = "Install extension"
    case enable = "Enable extension"
    case permissions = "Review permissions"
    case unavailable = "Extension unavailable"
    case blocked = "Extension blocked · update required"

    var id: Self { self }
    var errorDescription: String? { NSLocalizedString(rawValue, comment: "Usage extension card action") }

    static func status(for error: Error) -> Self? {
        switch error {
        case let status as Self: status
        case ExtensionCallError.permissionDenied, ExtensionCallError.permissionPending: .permissions
        case ExtensionVerificationError.revoked: .blocked
        case ExtensionCatalogService.InstallError.disabled: .enable
        case ExtensionCallError.extensionBlocked: .unavailable
        default: nil
        }
    }
}

/// The host binds the integration, workspace and credentials before dispatch. Registry lookups
/// always resolve the current verified generation, including after an install or update.
nonisolated struct ExtensionUsagePlugin: UsagePlugin {
    let descriptor: UsagePluginDescriptor
    private weak var appState: AppState?

    init(_ provider: ExtensionManifest.UsageProvider, appState: AppState) {
        descriptor = .init(id: provider.pluginID, title: provider.title, authentication: provider.authentication ?? "",
                           resourceLabel: provider.fields?["resource"] ?? "")
        self.appState = appState
    }

    @MainActor func fetch(configuration: UsageIntegration, credential: String, now: Date) async throws -> UsagePluginSnapshot {
        guard let appState, let workspace = appState.usageExtensionWorkspace(for: configuration),
              let panel = ExtensionCatalogController.shared.installedUsagePanel(pluginID: configuration.pluginID, workspace: workspace) else {
            throw UsageExtensionStatus.unavailable
        }
        return try await AgentExtensionRuntime.shared.fetchUsage(configuration, bundleIdentifier: panel.bundleIdentifier,
                                                                workspace: workspace, appState: appState)
    }

    @MainActor func detailView(snapshot: UsagePluginSnapshot, configuration: UsageCardConfiguration) -> AnyView {
        if let appState, let panel = appState.usageScene(snapshot: snapshot, scene: "usage-detail") {
            return AnyView(ExtensionSceneView(extension: panel, scene: "usage-detail",
                                              snapshot: try? JSONEncoder().encode(snapshot),
                                              configuration: try? JSONEncoder().encode(configuration),
                                              integration: appState.usageDashboard.integrations.first { $0.id == snapshot.id }, appState: appState))
        }
        return AnyView(UsagePluginDetailView(snapshot: snapshot, configuration: configuration))
    }
}

extension AppState {
    func usageExtensionWorkspace(for integration: UsageIntegration) -> URL? {
        if let projectID = integration.projectID {
            guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
            let selected = registeredWindows().first { $0.selectedProject?.id == projectID }
            let path = selected.flatMap { effectiveCwd(in: $0) } ?? project.path
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        // Global usage has no project file authority. Its root must never contain workspace data.
        return activeWorkspace.storageURL.appending(path: "ExtensionUsageRoot", directoryHint: .isDirectory)
    }

    /// Seed each saved provider independently. An unavailable project or a damaged archive must
    /// not prevent unrelated integrations from receiving their signed bundled releases.
    func seedDashboardUsageExtensions() async {
        let neutral = activeWorkspace.storageURL.appending(path: "ExtensionUsageRoot", directoryHint: .isDirectory)
        var requested = Set<String>()
        for integration in usageDashboard.integrations where requested.insert(integration.pluginID).inserted {
            let workspace = usageExtensionWorkspace(for: integration) ?? neutral
            do {
                if workspace == neutral { try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true) }
                try await ExtensionCatalogController.shared.seedUsage(integration.pluginID, workspace: workspace)
            } catch {
                Logger(subsystem: "app.rxlab.flowcy.code", category: "Extensions")
                    .error("Could not seed usage provider \(integration.pluginID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func prepareUsageExtension(_ integration: UsageIntegration) async throws -> ActivatedExtension {
        guard let workspace = usageExtensionWorkspace(for: integration) else { throw UsageExtensionStatus.unavailable }
        if integration.projectID == nil {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }
        return try await ExtensionCatalogController.shared.usagePanel(pluginID: integration.pluginID, workspace: workspace)
    }

    func usageScene(snapshot: UsagePluginSnapshot, scene: String) -> ActivatedExtension? {
        guard ExtensionPluginAPI.v2Enabled,
              let integration = usageDashboard.integrations.first(where: { $0.id == snapshot.id }),
              let workspace = usageExtensionWorkspace(for: integration),
              let panel = ExtensionCatalogController.shared.installedUsagePanel(pluginID: integration.pluginID, workspace: workspace),
              panel.manifest.contributes.sceneIDs.contains(scene) else { return nil }
        return panel
    }

    func usageExtensionStatus(for integration: UsageIntegration) -> UsageExtensionStatus? {
        guard ExtensionPluginAPI.v2Enabled else { return nil }
        let catalog = ExtensionCatalogController.shared
        let metadata = catalog.usageMetadata(integration.pluginID)
        if metadata?.verification?.blocked == true { return .blocked }
        let id = metadata?.manifest?.id ?? BundledUsageExtensions.releaseID(for: integration.pluginID)
        if catalog.disabledIDs.contains(id) || catalog.needsSystemEnablement.contains(id) { return .enable }
        if metadata == nil {
            guard let workspace = usageExtensionWorkspace(for: integration),
                  catalog.installedUsagePanel(pluginID: integration.pluginID, workspace: workspace) != nil else { return .install }
        }
        return usagePlugins.extensionStatuses[integration.id]
    }
}
