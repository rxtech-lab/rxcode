import CryptoKit
import Foundation
import Testing
@testable import RxCodeCore

@Suite("Notion OAuth")
struct NotionOAuthTests {

    private func callback(_ items: [String: String]) -> URL {
        var components = URLComponents(string: "rxcode://notion-callback")!
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    @Test("Start URL carries the public key and nonce")
    func startURL() throws {
        let session = NotionOAuthSession()
        let url = session.startURL(relayBaseURL: URL(string: "https://relaycode.rxlab.app")!)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.path == "/notion/oauth/start")
        #expect(items.first { $0.name == "nonce" }?.value == session.nonce)
        let key = try #require(items.first { $0.name == "pubkey" }?.value.flatMap(Data.init(base64URLEncoded:)))
        #expect(key == session.publicKey)
        #expect(key.count == 32)
    }

    @Test("A sealed callback decrypts to the credential")
    func roundTrip() throws {
        let session = NotionOAuthSession()
        let credential = NotionCredential(accessToken: "ntn_a", refreshToken: "nrt_b", workspaceId: "ws", workspaceName: "Acme")
        let sealed = try NotionOAuthSession.seal(credential, to: session.publicKey)
        let url = callback([
            "n": session.nonce,
            "epk": sealed.epk.base64URLEncoded,
            "iv": sealed.iv.base64URLEncoded,
            "ct": sealed.ciphertext.base64URLEncoded,
        ])
        #expect(try session.credential(from: url) == credential)

        // Another attempt's key can't open it, and a mismatched nonce is refused.
        #expect(throws: NotionOAuthError.invalidCallback) { try NotionOAuthSession().credential(from: url) }
    }

    @Test("Decrypts an envelope sealed by the Go relay")
    func relayVector() throws {
        // relay-server/notion.go `sealNotionEnvelope` output for the private
        // key with bytes 1...32.
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        let session = NotionOAuthSession(privateKey: privateKey, nonce: "vector-nonce-0000")
        let url = callback([
            "n": "vector-nonce-0000",
            "epk": "BBOR0mU3Qc_JaueT1WHmANtPxRKPhXIKHdu6eKnsri0",
            "iv": "oKRGD4yA-C3cv-YJ",
            "ct": "FlVpgoKQUB7wlC2BfykOxyBQV16BT1rsiO2KYucvw8vDVPr3lEhoV-1x9vMiqWizlxQhGfNbtHSpcSbpP33qnxqXFh1REkE9b25TFejxqFCBwWtwv7W9e7MutpMWltlMJ7A5lV_ttdhCrJoNbuANR2rGh8c_2zL9FZ6v1DcAtfqO4KOJnCBhwXRDeL607IU",
        ])
        let credential = try session.credential(from: url)
        #expect(credential == NotionCredential(
            accessToken: "ntn_vector",
            refreshToken: "nrt_vector",
            workspaceId: "ws-1",
            workspaceName: "Vector Space"
        ))
    }

    @Test("Relay errors map to cancellation or failure")
    func errors() {
        let session = NotionOAuthSession()
        #expect(throws: NotionOAuthError.cancelled) {
            try session.credential(from: callback(["n": session.nonce, "error": "access_denied"]))
        }
        #expect(throws: NotionOAuthError.denied("token exchange failed")) {
            try session.credential(from: callback(["n": session.nonce, "error": "token exchange failed"]))
        }
    }

    @Test("Stored credentials decode, including pasted tokens saved before OAuth")
    func credentialStorage() throws {
        #expect(NotionCredential.decode(Data("ntn_pasted".utf8)) == NotionCredential(accessToken: "ntn_pasted"))
        #expect(NotionCredential.decode(Data()) == nil)

        let oauth = NotionCredential(accessToken: "a", refreshToken: "r", workspaceId: "w", workspaceName: "Acme")
        #expect(NotionCredential.decode(try oauth.encoded()) == oauth)
        #expect(oauth.isOAuth)
        #expect(!NotionCredential(accessToken: "x").isOAuth)

        let refreshed = oauth.refreshed(with: NotionCredential(accessToken: "a2", refreshToken: "r2"))
        #expect(refreshed == NotionCredential(accessToken: "a2", refreshToken: "r2", workspaceId: "w", workspaceName: "Acme"))

        var viaRelay = oauth
        viaRelay.relayURL = "https://relay.example.com"
        #expect(NotionCredential.decode(try viaRelay.encoded())?.relayURL == "https://relay.example.com")
        #expect(viaRelay.refreshed(with: NotionCredential(accessToken: "a3")).relayURL == "https://relay.example.com")
    }

    @Test("Relay WebSocket URLs map to their HTTP base")
    func relayBaseURL() {
        func base(_ string: String) -> String? {
            NotionOAuthSession.httpBaseURL(forRelay: URL(string: string)!)?.absoluteString
        }
        #expect(base("wss://relaycode.rxlab.app") == "https://relaycode.rxlab.app")
        #expect(base("wss://relaycode.rxlab.app/ws") == "https://relaycode.rxlab.app")
        #expect(base("ws://localhost:8787/ws?x=1") == "http://localhost:8787")
        #expect(base("wss://example.com/relay/ws") == "https://example.com/relay")
        #expect(base("https://example.com/relay/") == "https://example.com/relay")
        #expect(base("ftp://example.com") == nil)
    }
}
