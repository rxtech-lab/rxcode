import Foundation
import CryptoKit
import Security

/// A long-term Curve25519 keypair stored in the Keychain. Identity is per
/// device — desktops, iPhones, and iPads each generate their own and use the
/// public key as their address on the relay.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
    public var publicKeyHex: String { publicKey.rawRepresentation.hexString }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Load the device's keypair, creating one on first run.
    ///
    /// - Parameters:
    ///   - service: Keychain service identifier. Pass a stable per-app value.
    ///   - accessGroup: Keychain access group. Pass non-nil to share the
    ///     identity between the main app and a Notification Service Extension
    ///     (both must enable the matching `keychain-access-groups` entitlement).
    public static func loadOrCreate(
        service: String = "com.idealapp.RxCode.deviceKey",
        accessGroup: String? = nil
    ) throws -> DeviceIdentity {
        if let existing = try Keychain.read(service: service, accessGroup: accessGroup) {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: existing)
            return DeviceIdentity(privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try Keychain.write(key.rawRepresentation, service: service, accessGroup: accessGroup)
        return DeviceIdentity(privateKey: key)
    }

    /// Discard the existing identity (e.g. user tapped "Unpair from everything"
    /// on mobile). The next `loadOrCreate` call generates a fresh keypair.
    public static func reset(
        service: String = "com.idealapp.RxCode.deviceKey",
        accessGroup: String? = nil
    ) throws {
        try Keychain.delete(service: service, accessGroup: accessGroup)
    }

    /// Resolve the fully-qualified keychain access group at runtime.
    ///
    /// The entitlement is written as `$(AppIdentifierPrefix)foo.bar` and the
    /// build system expands it to `TEAMID.foo.bar`. On iOS, `SecItem*` requires
    /// the **prefixed** form at runtime — passing the bare suffix yields
    /// `errSecMissingEntitlement` (-34018).
    ///
    /// We discover the team prefix by writing a probe keychain item with no
    /// access group specified (the system then assigns the default, which is
    /// the first entry from the entitlement's `keychain-access-groups` — fully
    /// prefixed) and reading back `kSecAttrAccessGroup`. Result is cached.
    public static func resolveAccessGroup(suffix: String) -> String {
        if let cached = cachedPrefix {
            return cached + suffix
        }
        if let prefix = discoverTeamPrefix() {
            cachedPrefix = prefix
            return prefix + suffix
        }
        // Unsigned macOS dev builds or sandbox-less contexts: fall back to the
        // bare suffix (macOS is lenient; iOS isn't, but at that point there's
        // nothing we can do).
        return suffix
    }

    // The prefix is deterministic for the process lifetime, so a benign race
    // where two callers both discover it yields the same value.
    private nonisolated(unsafe) static var cachedPrefix: String?

    private static func discoverTeamPrefix() -> String? {
        let probeService = "rxcode.devid.prefixprobe"
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "probe",
        ]
        // Try to read; if not present, add it (system will assign default
        // access group). Then re-read attributes.
        var readQuery = baseQuery
        readQuery[kSecReturnAttributes as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        var status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if status == errSecItemNotFound {
            var addAttrs = baseQuery
            addAttrs[kSecValueData as String] = Data([0])
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addAttrs as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                return nil
            }
            status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let dict = item as? [String: Any],
              let group = dict[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else {
            return nil
        }
        return String(group[..<group.index(after: dot)])  // includes trailing dot
    }
}

enum Keychain {
    static func read(service: String, accessGroup: String?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.osStatus(status)
        }
        return data
    }

    static func write(_ data: Data, service: String, accessGroup: String?) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let accessGroup { attributes[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    static func delete(service: String, accessGroup: String?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }
}

enum KeychainError: Error {
    case osStatus(OSStatus)
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i..<i + 2]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self = Data(bytes)
    }
}
