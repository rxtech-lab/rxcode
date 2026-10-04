import Foundation
import XCTest
@testable import RxCodeCore

final class ACPClientVersionTests: XCTestCase {
    func testOlderClientRecordsDecodeWithoutInstalledVersion() throws {
        let original = ACPClientSpec(
            registryId: "example",
            displayName: "Example",
            launch: .npx(package: "example", args: [], env: [:])
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "installedVersion")

        let decoded = try JSONDecoder().decode(
            ACPClientSpec.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.installedVersion)
        XCTAssertEqual(decoded.registryId, "example")
    }

    func testSelectedVersionPersists() throws {
        let client = ACPClientSpec(
            registryId: "example",
            installedVersion: "1.2.3",
            displayName: "Example",
            launch: .npx(package: "example", args: [], env: [:])
        )
        let decoded = try JSONDecoder().decode(ACPClientSpec.self, from: JSONEncoder().encode(client))
        XCTAssertEqual(decoded.installedVersion, "1.2.3")
    }

    func testNpxLaunchUsesSelectedVersionForScopedAndUnscopedPackages() {
        XCTAssertEqual(ACPPackageVersion.npx("@scope/agent@1.0.0", version: "2.1.0"), "@scope/agent@2.1.0")
        XCTAssertEqual(ACPPackageVersion.npx("agent", version: "2.1.0"), "agent@2.1.0")
        XCTAssertFalse(ACPPackageVersion.isPinned(
            .npx(package: "@scope/agent@1.0.0", args: [], env: [:]), to: "2.1.0"
        ))
        XCTAssertTrue(ACPPackageVersion.isPinned(
            .npx(package: "@scope/agent@2.1.0", args: [], env: [:]), to: "2.1.0"
        ))
    }

    func testUvxLaunchUsesSelectedVersionForBothRegistryFormats() {
        XCTAssertEqual(ACPPackageVersion.uvx("fast-agent-acp==0.10.1", version: "0.11.0"), "fast-agent-acp@0.11.0")
        XCTAssertEqual(ACPPackageVersion.uvx("minion-code@0.1.44", version: "0.2.0"), "minion-code@0.2.0")
        XCTAssertTrue(ACPPackageVersion.isPinned(
            .uvx(package: "fast-agent-acp==0.11.0", args: [], env: [:]), to: "0.11.0"
        ))
        XCTAssertFalse(ACPPackageVersion.isPinned(
            .uvx(package: "fast-agent-acp", args: [], env: [:]), to: "0.11.0"
        ))
    }

    func testInvalidPackageDoesNotProduceVersionedLaunch() {
        XCTAssertNil(ACPPackageVersion.npx("https://example.com/agent", version: "1.0.0"))
        XCTAssertNil(ACPPackageVersion.uvx("agent[extra]", version: "1.0.0"))
    }

    func testExactVersionValidation() {
        XCTAssertTrue(ACPPackageVersion.isValid("1.2.3"))
        XCTAssertTrue(ACPPackageVersion.isValid("1.2.3-preview.4"))
        XCTAssertTrue(ACPPackageVersion.isValid("1.2.3+build.5"))
        XCTAssertFalse(ACPPackageVersion.isValid("latest"))
        XCTAssertFalse(ACPPackageVersion.isValid("1.2.3 --help"))
        XCTAssertFalse(ACPPackageVersion.isValid("../1.2.3"))
        XCTAssertEqual(ACPPackageVersion.npx("agent@2.0.0", version: "1.2.3"), "agent@1.2.3")
        XCTAssertEqual(ACPPackageVersion.uvx("agent==2.0.0", version: "1.2.3"), "agent@1.2.3")
    }
}
