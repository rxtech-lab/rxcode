import Foundation
import os
import Security

enum KeychainHelper {

    private static let logger = Logger(subsystem: "com.claudework", category: "Keychain")

    /// Above this, the SecItem call almost certainly blocked on a macOS
    /// "wants to use confidential information" permission dialog — a synchronous
    /// keychain read returns in microseconds otherwise. Use this to pin down
    /// which caller triggers the prompt.
    private static let promptSuspicionThreshold: Duration = .milliseconds(250)

    private nonisolated static func describe(_ status: OSStatus) -> String {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
        return "\(status) (\(message))"
    }

    private nonisolated static func logTiming(
        op: String,
        service: String,
        account: String?,
        status: OSStatus,
        elapsed: Duration,
        caller: String,
        file: String,
        line: Int
    ) {
        let acct = account ?? "<any>"
        let location = "\(file):\(line) \(caller)"
        let ms = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1e3
        if elapsed > promptSuspicionThreshold {
            logger.warning(
                "\(op, privacy: .public) service=\(service, privacy: .public) account=\(acct, privacy: .public) status=\(describe(status), privacy: .public) elapsed=\(ms, privacy: .public)ms ⚠️ SLOW — likely a keychain permission prompt — caller=\(location, privacy: .public)"
            )
        } else {
            logger.debug(
                "\(op, privacy: .public) service=\(service, privacy: .public) account=\(acct, privacy: .public) status=\(describe(status), privacy: .public) elapsed=\(ms, privacy: .public)ms caller=\(location, privacy: .public)"
            )
        }
    }

    // MARK: - Read (SecItem API — same process that wrote the item)

    nonisolated static func read(
        service: String,
        account: String? = nil,
        caller: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        let clock = ContinuousClock()
        let start = clock.now
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let elapsed = clock.now - start

        logTiming(
            op: "read", service: service, account: account, status: status,
            elapsed: elapsed, caller: caller, file: file, line: line
        )

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    nonisolated static func readString(
        service: String,
        account: String? = nil,
        caller: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) -> String? {
        guard let data = read(service: service, account: account, caller: caller, file: file, line: line) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Write / Delete (SecItem API — own app items)

    nonisolated static func save(
        _ data: Data,
        service: String,
        account: String,
        caller: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let clock = ContinuousClock()
        let start = clock.now
        var status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        var op = "save(update)"

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
            op = "save(add)"
        }
        let elapsed = clock.now - start

        logTiming(
            op: op, service: service, account: account, status: status,
            elapsed: elapsed, caller: caller, file: file, line: line
        )

        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
    }

    nonisolated static func delete(
        service: String,
        account: String,
        caller: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let clock = ContinuousClock()
        let start = clock.now
        let status = SecItemDelete(query as CFDictionary)
        let elapsed = clock.now - start

        logTiming(
            op: "delete", service: service, account: account, status: status,
            elapsed: elapsed, caller: caller, file: file, line: line
        )

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    enum KeychainError: Error {
        case operationFailed(OSStatus)
    }
}
