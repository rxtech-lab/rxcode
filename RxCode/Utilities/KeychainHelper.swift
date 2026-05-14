import Foundation
import Security

enum KeychainHelper {

    // MARK: - Read (security CLI — reads items created by other apps without a popup)

    nonisolated static func read(service: String, account: String? = nil) -> Data? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account {
            args.insert(contentsOf: ["-a", account], at: 1)
        }
        guard let output = runSecurity(args) else { return nil }
        return output.data(using: .utf8)
    }

    nonisolated static func readString(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account {
            args.insert(contentsOf: ["-a", account], at: 1)
        }
        return runSecurity(args)
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

    // MARK: - Private

    private nonisolated static func runSecurity(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    enum KeychainError: Error {
        case operationFailed(OSStatus)
    }
}
