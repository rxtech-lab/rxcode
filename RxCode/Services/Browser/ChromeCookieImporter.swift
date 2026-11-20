import CommonCrypto
import Foundation
import Security
import SQLite3

/// A Chrome profile that has a cookie database on this Mac.
nonisolated struct ChromeProfile: Identifiable, Hashable, Sendable {
    let name: String
    let cookiesURL: URL
    /// The original URL keeps access to a user-selected folder available for import.
    let dataDirectory: URL
    var id: String { cookiesURL.path }
}

/// A decrypted Chrome cookie, kept as plain values so it can cross actors.
nonisolated struct ChromeCookie: Sendable, Equatable {
    var domain: String
    var path: String
    var name: String
    var value: String
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    /// Chrome's `samesite` column: -1 unspecified, 0 none, 1 lax, 2 strict.
    var sameSite: Int

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path.isEmpty ? "/" : path, .name: name, .value: value,
        ]
        if let expires { properties[.expires] = expires } else { properties[.discard] = "TRUE" }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite {
        case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }

    /// Whether the cookie applies to one of the sites, such as `github.com`.
    func matches(sites: [String]) -> Bool {
        guard !sites.isEmpty else { return true }
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

nonisolated enum ChromeCookieImportError: LocalizedError, Equatable {
    case keychainDenied
    case keychainMissing
    case unreadableDatabase(String)

    var errorDescription: String? {
        switch self {
        case .keychainDenied:
            String(localized: "Keychain access to Chrome Safe Storage was denied.")
        case .keychainMissing:
            String(localized: "Chrome’s encryption key was not found in the Keychain. Open Chrome once, then try again.")
        case .unreadableDatabase(let message):
            String(localized: "Chrome’s cookie database could not be read: \(message)")
        }
    }
}

/// Reads cookies from Google Chrome on macOS. Chrome encrypts cookie values with
/// AES-128-CBC using a key derived from the "Chrome Safe Storage" Keychain item,
/// so macOS asks the user before the key is released.
nonisolated enum ChromeCookieImporter {
    static var chromeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// Profiles with a cookie database, named as Chrome's profile menu shows them.
    static func profiles(in root: URL = chromeDirectory) throws -> [ChromeProfile] {
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        let names = profileNames(in: root)
        return entries.compactMap { directory -> ChromeProfile? in
            let candidates = [directory.appendingPathComponent("Cookies"), directory.appendingPathComponent("Network/Cookies")]
            guard let cookies = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }
            let folder = directory.lastPathComponent
            return ChromeProfile(name: names[folder] ?? folder, cookiesURL: cookies, dataDirectory: root)
        }
        .sorted { lhs, rhs in
            // Keep the default profile first, then follow Chrome's display names.
            if lhs.cookiesURL.pathComponents.contains("Default") != rhs.cookiesURL.pathComponents.contains("Default") {
                return lhs.cookiesURL.pathComponents.contains("Default")
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func profileNames(in root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        return cache.reduce(into: [:]) { result, entry in
            if let name = (entry.value as? [String: Any])?["name"] as? String, !name.isEmpty { result[entry.key] = name }
        }
    }

    /// Decrypts the profile's unexpired cookies. Prompts for Keychain access.
    static func cookies(from profile: ChromeProfile, sites: [String] = [], now: Date = Date()) throws -> [ChromeCookie] {
        let directory = profile.dataDirectory
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }

        let key = try deriveKey(password: try safeStoragePassword())
        return try readCookies(at: profile.cookiesURL, key: key, sites: sites, now: now)
    }

    /// Splits user input such as "github.com, https://vercel.com" into bare hosts.
    static func sites(from input: String) -> [String] {
        input.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { part in
            var text = part.trimmingCharacters(in: .whitespaces).lowercased()
            if let host = URL(string: text)?.host, text.contains("://") { text = host }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            return text.isEmpty ? nil : text
        }
    }

    // MARK: - Keychain and decryption

    private static func safeStoragePassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw ChromeCookieImportError.keychainMissing }
            return data
        case errSecItemNotFound: throw ChromeCookieImportError.keychainMissing
        default: throw ChromeCookieImportError.keychainDenied
        }
    }

    static func deriveKey(password: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                )
            }
        }
        guard status == kCCSuccess else { throw ChromeCookieImportError.keychainDenied }
        return key
    }

    /// Decrypts a `v10` value. Databases from schema 24 onward prefix the
    /// plaintext with a SHA-256 digest of the host, which is dropped.
    static func decrypt(_ encrypted: Data, key: Data, stripsDomainDigest: Bool) -> String? {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else { return nil }
        let payload = encrypted.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv,
                            payloadBytes.baseAddress, payload.count,
                            outputBytes.baseAddress, outputCapacity, &length)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plaintext = output.prefix(length)
        if stripsDomainDigest {
            guard plaintext.count >= 32 else { return nil }
            plaintext = plaintext.dropFirst(32)
        }
        return String(data: Data(plaintext), encoding: .utf8)
    }

    // MARK: - Database

    private static func readCookies(at url: URL, key: Data, sites: [String], now: Date) throws -> [ChromeCookie] {
        // Chrome keeps the database locked while running, so read a private copy.
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("rxcode-chrome-cookies-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("Cookies")
        do { try fileManager.copyItem(at: url, to: copy) }
        catch { throw ChromeCookieImportError.unreadableDatabase(error.localizedDescription) }
        for suffix in ["-wal", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            sqlite3_close(database)
            throw ChromeCookieImportError.unreadableDatabase(message)
        }
        defer { sqlite3_close(database) }

        let stripsDomainDigest = schemaVersion(database) >= 24
        var statement: OpaquePointer?
        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChromeCookieImportError.unreadableDatabase(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [ChromeCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let expiresUTC = sqlite3_column_int64(statement, 5)
            let expires = expiresUTC == 0 ? nil : chromeDate(expiresUTC)
            if let expires, expires <= now { continue }
            var cookie = ChromeCookie(
                domain: text(statement, 0), path: text(statement, 4), name: text(statement, 1), value: text(statement, 2),
                expires: expires, isSecure: sqlite3_column_int(statement, 6) != 0,
                isHTTPOnly: sqlite3_column_int(statement, 7) != 0, sameSite: Int(sqlite3_column_int(statement, 8))
            )
            guard !cookie.domain.isEmpty, !cookie.name.isEmpty, cookie.matches(sites: sites) else { continue }
            if cookie.value.isEmpty {
                let count = Int(sqlite3_column_bytes(statement, 3))
                guard count > 0, let bytes = sqlite3_column_blob(statement, 3),
                      let value = decrypt(Data(bytes: bytes, count: count), key: key, stripsDomainDigest: stripsDomainDigest)
                else { continue }
                cookie.value = value
            }
            cookies.append(cookie)
        }
        return cookies
    }

    private static func schemaVersion(_ database: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(text(statement, 0)) ?? 0
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Chrome stores times as microseconds since 1601-01-01 UTC.
    static func chromeDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }
}
