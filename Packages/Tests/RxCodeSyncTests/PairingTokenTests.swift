import Foundation
import Testing
@testable import RxCodeSync

@Suite("Pairing token links")
struct PairingTokenTests {
    @Test("QR string is an HTTPS pairing deeplink with token and relay")
    func qrStringUsesPairingDeeplink() throws {
        let token = makeToken(relayURL: "wss://relay.rxlab.app/ws")
        let qrString = try token.qrString()
        let url = try #require(URL(string: qrString))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        #expect(url.scheme == "https")
        #expect(url.host == PairingToken.deeplinkHost)
        #expect(url.path == PairingToken.deeplinkPath)
        #expect(queryItems["token"] != nil)
        #expect(queryItems["relay"] == "wss://relay.rxlab.app/ws")
    }

    @Test("Parser accepts HTTPS deeplinks and legacy QR payloads")
    func parseAcceptsNewAndLegacyFormats() throws {
        let token = makeToken(relayURL: "ws://localhost:8787/ws")

        let deeplink = try token.qrString()
        let parsedDeeplink = try PairingToken.parse(deeplink)
        #expect(parsedDeeplink.sessionID == token.sessionID)
        #expect(parsedDeeplink.relayURL == token.relayURL)

        let legacy = try token.legacyQRString()
        let parsedLegacy = try PairingToken.parse(legacy)
        #expect(parsedLegacy.sessionID == token.sessionID)
        #expect(parsedLegacy.relayURL == token.relayURL)
    }

    private func makeToken(relayURL: String) -> PairingToken {
        PairingToken(
            relayURL: relayURL,
            desktopPubkeyHex: String(repeating: "a", count: 64),
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            oneTimeSecretHex: String(repeating: "b", count: 32),
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            desktopName: "Mac"
        )
    }
}
