import XCTest
@testable import RxCode

final class HuggingFaceAuthTests: XCTestCase {
    func testAuthorizeURLUsesPKCEAndTheFixedCallback() throws {
        let (url, state, verifier) = HuggingFaceOAuth.authorize(redirectURI: HuggingFaceOAuth.callbackURL)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertEqual(items["client_id"], HuggingFaceOAuth.clientID)
        XCTAssertEqual(items["redirect_uri"], "http://localhost:47617/oauth/callback")
        XCTAssertEqual(items["state"], state)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "openid profile read-repos gated-repos")
        let challenge = try XCTUnwrap(items["code_challenge"])
        XCTAssertFalse(challenge.isEmpty)
        XCTAssertNotEqual(challenge, verifier)
        XCTAssertFalse(challenge.contains("="))
    }

    func testTokenIsDroppedOnlyWhenRedirectedToAnotherHost() {
        var original = URLRequest(url: URL(string: "https://huggingface.co/me/model/resolve/main/model.gguf")!)
        original.setValue("Bearer hf_secret", forHTTPHeaderField: "Authorization")

        var sameHost = URLRequest(url: URL(string: "https://huggingface.co/api/resolve-cache/model.gguf")!)
        sameHost.setValue("Bearer hf_secret", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(HuggingFaceRedirectGuard.strippingCrossHostAuthorization(sameHost, from: original)
            .value(forHTTPHeaderField: "Authorization"), "Bearer hf_secret")

        var cdn = URLRequest(url: URL(string: "https://cas-bridge.xethub.hf.co/signed?X-Amz-Signature=abc")!)
        cdn.setValue("Bearer hf_secret", forHTTPHeaderField: "Authorization")
        XCTAssertNil(HuggingFaceRedirectGuard.strippingCrossHostAuthorization(cdn, from: original)
            .value(forHTTPHeaderField: "Authorization"))
    }

    func testSummaryReadsPrivateAndGatedFlags() {
        let privateRepo = HuggingFaceClient.summary(["id": "me/secret-GGUF", "private": true, "gated": false], format: .gguf)
        XCTAssertEqual(privateRepo?.isPrivate, true)
        XCTAssertEqual(privateRepo?.isGated, false)

        let gated = HuggingFaceClient.summary(["id": "meta-llama/Llama-GGUF", "private": false, "gated": "manual"], format: .gguf)
        XCTAssertEqual(gated?.isPrivate, false)
        XCTAssertEqual(gated?.isGated, true)

        let open = HuggingFaceClient.summary(["id": "org/open-GGUF"], format: .gguf)
        XCTAssertEqual(open?.isPrivate, false)
        XCTAssertEqual(open?.isGated, false)
    }
}
