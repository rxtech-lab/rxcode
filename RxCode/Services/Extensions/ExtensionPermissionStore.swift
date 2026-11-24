import AppKit
import Foundation
import Observation
import RxCodeCore

/// The host chooses the identity. A development bundle and a signed package have
/// separate grants even when their editable manifests declare the same ID.
@Observable @MainActor
final class ExtensionPermissionStore {
    static let shared = ExtensionPermissionStore()

    typealias Prompt = @MainActor (ExtensionPermission, ExtensionManifest, String) async -> ExtensionPermissionDecisions.Decision
    private let prompt: Prompt
    private let file: PermissionFile
    private var snapshot = PermissionFile.Snapshot()
    @ObservationIgnored private var prompts: [String: Task<ExtensionPermissionDecisions.Access, Error>] = [:]
    @ObservationIgnored private var promptTail: Task<ExtensionPermissionDecisions.Access, Error>?

    init(url: URL = AppSupport.bundleScopedURL.appending(path: "extension-permissions.json"),
         prompt: @escaping Prompt = ExtensionPermissionPrompt.present) {
        file = PermissionFile(url: url)
        self.prompt = prompt
    }

    func load() async throws { apply(try await file.load()) }

    func decision(for permission: ExtensionPermission, identity: String) -> ExtensionPermissionDecisions.Decision? {
        snapshot.values.decision(for: permission, extensionID: identity)
    }

    func set(_ decision: ExtensionPermissionDecisions.Decision, permission: ExtensionPermission, identity: String) async throws {
        let previous = self.decision(for: permission, identity: identity)
        apply(try await file.update { $0.decide(decision, permission: permission, extensionID: identity) })
        if decision == .confirm, previous != .confirm, self === Self.shared {
            Task { await ExtensionCatalogController.shared.refreshUsageForExtension(identity) }
        }
    }

    func review(manifest: ExtensionManifest, identity: String, interactive: Bool = true) async throws {
        let prefix = identity + "/"
        let current = Set(manifest.permissions.map { prefix + $0.id.rawValue + "/" + $0.scopeDigest })
        for (key, prompt) in prompts where key.hasPrefix(prefix) && !current.contains(key) { prompt.cancel() }
        apply(try await file.update { $0.reconcile(manifest, identity: identity) })
        guard interactive else { return }
        for permission in manifest.permissions where permission.risk == .high {
            try Task.checkCancellation()
            _ = try await authorize(permission.id, manifest: manifest, identity: identity, origin: .userInitiated)
        }
    }

    func authorize(_ id: ExtensionPermission.ID, manifest: ExtensionManifest, identity: String,
                   origin: ExtensionPermissionDecisions.Origin) async throws -> ExtensionPermissionDecisions.Access {
        try await load()
        let access = snapshot.values.access(to: id, in: manifest, origin: origin, identity: identity)
        guard access == .needsPrompt, let permission = manifest.permissions.first(where: { $0.id == id }) else { return access }
        let key = identity + "/" + id.rawValue + "/" + permission.scopeDigest
        if let existing = prompts[key] { return try await existing.value }
        let prior = promptTail
        let task = Task<ExtensionPermissionDecisions.Access, Error> { @MainActor in
            _ = await prior?.result
            try Task.checkCancellation()
            let decision = await prompt(permission, manifest, identity)
            try Task.checkCancellation()
            try await set(decision, permission: permission, identity: identity)
            switch decision {
            case .confirm: return .granted
            case .skip: return .permissionPending
            case .reject: return .permissionDenied
            }
        }
        prompts[key] = task
        promptTail = task
        defer {
            prompts[key] = nil
            if prompts.isEmpty { promptTail = nil }
        }
        return try await task.value
    }

    private func apply(_ next: PermissionFile.Snapshot) {
        if next.revision >= snapshot.revision { snapshot = next }
    }
}

private actor PermissionFile {
    nonisolated struct Snapshot: Sendable {
        var revision = 0
        var values = ExtensionPermissionDecisions()
    }
    private var state: Snapshot?
    private let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> Snapshot {
        if let state { return state }
        var result = Snapshot()
        do {
            result.values = try JSONDecoder().decode(ExtensionPermissionDecisions.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {}
        state = result
        return result
    }

    func update(_ mutation: @Sendable (inout ExtensionPermissionDecisions) -> Void) throws -> Snapshot {
        var next = try load()
        mutation(&next.values)
        if next.values == state?.values { return next }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next.values).write(to: url, options: .atomic)
        next.revision += 1
        state = next
        return next
    }
}

@MainActor
private enum ExtensionPermissionPrompt {
    static func present(_ permission: ExtensionPermission, manifest: ExtensionManifest, identity: String) async -> ExtensionPermissionDecisions.Decision {
        guard var window = NSApp.keyWindow ?? NSApp.mainWindow else { return .skip }
        while let sheet = window.attachedSheet { window = sheet }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Allow \(manifest.name) to use \(permission.id.rawValue)?")
        alert.informativeText = [identity, permission.explanation, permission.slots?.joined(separator: ", ")]
            .compactMap { $0 }.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Confirm"))
        let skip = alert.addButton(withTitle: String(localized: "Skip"))
        skip.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Reject"))
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertFirstButtonReturn: return .confirm
        case .alertThirdButtonReturn: return .reject
        default: return .skip
        }
    }
}

extension ExtensionPermission {
    var explanation: String {
        switch id {
        case .projectRead: String(localized: "Read project files, excluding sensitive files.")
        case .storage: String(localized: "Save settings for this extension.")
        case .network: String(localized: "Make network requests to the listed domains.")
        case .credentialsUse: String(localized: "Use the listed credential slots for network requests.")
        case .usageLocalRead: String(localized: "Read local usage, rate limits and task costs.")
        case .diskRead: String(localized: "Read files outside the project and sensitive files.")
        case .contactsRead: String(localized: "Read contacts through RxCode.")
        case .vaultRead: String(localized: "Read RxCode Secrets after passkey verification.")
        case .vaultCreate: String(localized: "Create RxCode Secrets environments and files.")
        case .acpCredentialsUse: String(localized: "Use ACP account credentials for network requests.")
        }
    }
}
