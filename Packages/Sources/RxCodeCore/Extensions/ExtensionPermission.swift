import CryptoKit
import Foundation

public struct ExtensionPermission: Codable, Hashable, Sendable, Identifiable {
    public enum ID: String, CaseIterable, Codable, Sendable {
        case projectRead = "project.read"
        case storage, network
        case credentialsUse = "credentials.use"
        case usageLocalRead = "usage.local.read"
        case diskRead = "disk.read"
        case contactsRead = "contacts.read"
        case vaultRead = "vault.read"
        case vaultCreate = "vault.create"
        case acpCredentialsUse = "acp.credentials.use"
    }

    public enum Risk: String, Codable, Sendable {
        case implicit = "default"
        case standard, high
    }

    public let id: ID
    public let domains: [String]?
    public let slots: [String]?

    public init(id: ID, domains: [String]? = nil, slots: [String]? = nil) {
        self.id = id
        self.domains = domains
        self.slots = slots
    }

    public var risk: Risk {
        switch id {
        case .projectRead, .storage: .implicit
        case .network, .credentialsUse, .usageLocalRead: .standard
        case .diskRead, .contactsRead, .vaultRead, .vaultCreate, .acpCredentialsUse: .high
        }
    }

    public var scopeDigest: String {
        let values = (domains ?? slots ?? []).sorted()
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        switch id {
        case .network:
            guard slots == nil, let domains, !domains.isEmpty,
                  Set(domains).count == domains.count, domains.allSatisfy(ExtensionManifest.isDNSName) else {
                throw ExtensionManifest.ValidationError.invalidPermission(id)
            }
        case .credentialsUse, .acpCredentialsUse:
            guard domains == nil, let slots, !slots.isEmpty, Set(slots).count == slots.count,
                  slots.allSatisfy({ $0.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil }) else {
                throw ExtensionManifest.ValidationError.invalidPermission(id)
            }
        default:
            guard slots == nil, domains == nil else { throw ExtensionManifest.ValidationError.invalidPermission(id) }
        }
    }
}

/// Persist this value atomically after a successful install, update, or user decision.
public struct ExtensionPermissionDecisions: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable { case confirm, skip, reject }
    public enum Origin: Sendable { case background, userInitiated }
    public enum Access: Sendable { case granted, permissionDenied, permissionPending, needsPrompt }

    private var records: [String: [String: Decision]] = [:]
    public init() {}

    private func key(for permission: ExtensionPermission) -> String {
        "\(permission.id.rawValue):\(permission.scopeDigest)"
    }

    public func decision(for permission: ExtensionPermission, extensionID: String) -> Decision? {
        records[extensionID]?[key(for: permission)]
    }

    public mutating func decide(_ decision: Decision, permission: ExtensionPermission, extensionID: String) {
        guard permission.risk == .high else { return }
        records[extensionID, default: [:]][key(for: permission)] = decision
    }

    public mutating func reconcile(_ manifest: ExtensionManifest, identity: String? = nil) {
        let owner = identity ?? manifest.id
        let keys = Set(manifest.permissions.filter { $0.risk == .high }.map(key(for:)))
        records[owner] = records[owner]?.filter { keys.contains($0.key) }
    }

    public func access(to id: ExtensionPermission.ID, in manifest: ExtensionManifest, origin: Origin, identity: String? = nil) -> Access {
        guard let permission = manifest.effectivePermissions.first(where: { $0.id == id }) else {
            return .permissionDenied
        }
        guard permission.risk == .high else { return .granted }
        switch decision(for: permission, extensionID: identity ?? manifest.id) {
        case .confirm: return .granted
        case .reject: return .permissionDenied
        case .skip, nil: return origin == .userInitiated ? .needsPrompt : .permissionPending
        }
    }
}
