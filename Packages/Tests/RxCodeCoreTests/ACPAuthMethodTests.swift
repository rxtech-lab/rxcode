import Foundation
import XCTest
@testable import RxCodeCore

final class ACPAuthMethodTests: XCTestCase {
    private func parse(_ json: String) throws -> [ACPAuthMethod] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return ACPAuthMethod.parse(initializeResult: value)
    }

    func testParsesAgentEnvVarAndTerminalMethods() throws {
        let methods = try parse("""
        {"protocolVersion":1,"authMethods":[
          {"id":"oauth","name":"Log in with Google","description":"Browser sign-in"},
          {"id":"key","name":"API Key","type":"env_var","link":"https://example.com/keys",
           "vars":[{"name":"EXAMPLE_API_KEY","label":"Key"},{"name":"EXAMPLE_ORG","secret":false,"optional":true}]},
          {"id":"legacy-key","name":"Legacy","type":"env_var","varName":"LEGACY_KEY"},
          {"id":"setup","name":"Setup","type":"terminal","args":["--setup"],"env":{"MODE":"login"}},
          {"id":"unknown","name":"Unknown","type":"future-type"}
        ]}
        """)

        XCTAssertEqual(methods.map(\.id), ["oauth", "key", "legacy-key", "setup"])
        XCTAssertEqual(methods[0].kind, .agent)
        XCTAssertEqual(methods[0].description, "Browser sign-in")
        XCTAssertEqual(methods[1].kind, .envVar(vars: [
            .init(name: "EXAMPLE_API_KEY", label: "Key"),
            .init(name: "EXAMPLE_ORG", secret: false, optional: true)
        ], link: "https://example.com/keys"))
        XCTAssertEqual(methods[2].kind, .envVar(vars: [.init(name: "LEGACY_KEY")], link: nil))
        XCTAssertEqual(methods[3].kind, .terminal(command: nil, args: ["--setup"], env: ["MODE": "login"]))
    }

    func testTerminalAuthMetaBecomesTerminalMethod() throws {
        let methods = try parse("""
        {"authMethods":[{"id":"claude-login","name":"Log in","_meta":{"terminal-auth":
          {"command":"/usr/local/bin/node","args":["cli.js","/login"],"label":"Claude Login"}}}]}
        """)

        XCTAssertEqual(methods.first?.name, "Claude Login")
        XCTAssertEqual(methods.first?.kind, .terminal(
            command: "/usr/local/bin/node", args: ["cli.js", "/login"], env: [:]
        ))
    }

    func testMissingAuthMethodsYieldsEmptyList() throws {
        XCTAssertTrue(try parse(#"{"protocolVersion":1}"#).isEmpty)
    }

    func testLogoutRequiresAdvertisedCapability() throws {
        for (json, expected) in [
            (#"{"agentCapabilities":{"auth":{"logout":{}}}}"#, true),
            (#"{"agentCapabilities":{"auth":{"logout":null}}}"#, false),
            (#"{"agentCapabilities":{"auth":{}}}"#, false),
            (#"{"agentCapabilities":{}}"#, false)
        ] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            XCTAssertEqual(ACPAuthMethod.supportsLogout(initializeResult: value), expected)
        }
    }

    func testOlderClientRecordsDecodeWithoutAuthMethodId() throws {
        let original = ACPClientSpec(displayName: "Example", launch: .npx(package: "example", args: [], env: [:]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "authMethodId")
        let decoded = try JSONDecoder().decode(ACPClientSpec.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.authMethodId)
    }
}
