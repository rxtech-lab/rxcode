import Foundation
import Security

enum KeychainHelper {

    // MARK: - Read (SecItem API — same process that wrote the item)

    nonisolated static func read(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    nonisolated static func readString(service: String, account: String? = nil) -> String? {
        guard let data = read(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Write / Delete (SecItem API — own app items)

    nonisolated static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
    }

    nonisolated static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    enum KeychainError: Error {
        case operationFailed(OSStatus)
    }
}
