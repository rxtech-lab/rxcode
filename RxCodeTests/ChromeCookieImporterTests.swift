import CommonCrypto
import XCTest
@testable import RxCode

final class ChromeCookieImporterTests: XCTestCase {
    func testProfilesAreDiscoveredInTheSelectedDataFolder() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        XCTAssertTrue(try ChromeCookieImporter.profiles(in: directory).isEmpty)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }
        XCTAssertTrue(try ChromeCookieImporter.profiles(in: directory).isEmpty)

        let databases = [("Default/Cookies", "Personal"), ("Profile 2/Network/Cookies", "Work")]
        for (path, marker) in databases {
            let file = directory.appending(path: path)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try marker.write(to: file, atomically: true, encoding: .utf8)
        }
        try #"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 2":{"name":"Work"}}}}"#
            .write(to: directory.appending(path: "Local State"), atomically: true, encoding: .utf8)

        let profiles = try ChromeCookieImporter.profiles(in: directory)
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
        let markers = try profiles.map { try String(contentsOf: $0.cookiesURL, encoding: .utf8) }
        XCTAssertEqual(markers, ["Personal", "Work"])
        XCTAssertTrue(profiles.allSatisfy { $0.dataDirectory == directory })
    }

    func testProfileDiscoveryReportsAReadPermissionError() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o000])
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }

        XCTAssertThrowsError(try ChromeCookieImporter.profiles(in: directory)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
        }
    }

    func testDecryptsVersion10ValuesAndDropsHostDigest() throws {
        let key = try ChromeCookieImporter.deriveKey(password: Data("peanuts".utf8))
        let digest = Data(repeating: 0xAB, count: 32)
        let legacy = try encrypt(Data("session=abc".utf8), key: key)
        let current = try encrypt(digest + Data("session=abc".utf8), key: key)

        XCTAssertEqual(ChromeCookieImporter.decrypt(legacy, key: key, stripsDomainDigest: false), "session=abc")
        XCTAssertEqual(ChromeCookieImporter.decrypt(current, key: key, stripsDomainDigest: true), "session=abc")
        XCTAssertNil(ChromeCookieImporter.decrypt(Data("plain".utf8), key: key, stripsDomainDigest: false))
    }

    func testSiteFilterMatchesHostsAndSubdomains() {
        let sites = ChromeCookieImporter.sites(from: "https://GitHub.com/, vercel.com  .example.org")
        XCTAssertEqual(sites, ["github.com", "vercel.com", "example.org"])

        func cookie(_ domain: String) -> ChromeCookie {
            ChromeCookie(domain: domain, path: "/", name: "id", value: "1", expires: nil,
                         isSecure: true, isHTTPOnly: true, sameSite: 1)
        }
        XCTAssertTrue(cookie(".github.com").matches(sites: sites))
        XCTAssertTrue(cookie("api.vercel.com").matches(sites: sites))
        XCTAssertFalse(cookie("notgithub.com").matches(sites: sites))
        XCTAssertTrue(cookie("anything.dev").matches(sites: []))
    }

    func testConvertsChromeTimestampsAndBuildsHTTPCookies() throws {
        // 13_300_000_000_000_000 µs after 1601 is 2022-06-24 (Unix 1_655_526_400).
        let date = ChromeCookieImporter.chromeDate(13_300_000_000_000_000)
        XCTAssertEqual(date.timeIntervalSince1970, 1_655_526_400, accuracy: 1)

        let cookie = ChromeCookie(domain: ".github.com", path: "", name: "user_session", value: "token",
                                  expires: Date(timeIntervalSinceNow: 3600), isSecure: true, isHTTPOnly: true, sameSite: 1)
        let http = try XCTUnwrap(cookie.httpCookie)
        XCTAssertEqual(http.domain, ".github.com")
        XCTAssertEqual(http.path, "/")
        XCTAssertTrue(http.isSecure)
        XCTAssertTrue(http.isHTTPOnly)
        XCTAssertEqual(http.sameSitePolicy, .sameSiteLax)
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, plaintext.count,
                            out.baseAddress, capacity, &length)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + output.prefix(length)
    }
}
