import XCTest
@testable import RxCodeCore

final class AgentRuntimeVersionTests: XCTestCase {
    func testParsesRuntimeOutput() {
        XCTAssertEqual(AgentRuntimeVersion.parse("2.1.310 (Claude Code)\n"), "2.1.310")
        XCTAssertEqual(AgentRuntimeVersion.parse("codex-cli 0.164.0"), "0.164.0")
        XCTAssertEqual(AgentRuntimeVersion.parse("codex-cli 0.165.0-beta.2+build.1"), "0.165.0-beta.2+build.1")
        XCTAssertNil(AgentRuntimeVersion.parse(nil))
        XCTAssertNil(AgentRuntimeVersion.parse("unknown"))
    }

    func testOnlyNewerReleasesAreUpdates() {
        XCTAssertTrue(AgentRuntimeVersion.isUpdate("2.1.311", for: "2.1.310 (Claude Code)"))
        XCTAssertTrue(AgentRuntimeVersion.isUpdate("0.170.0", for: "codex-cli 0.99.0"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.164.0", for: "codex-cli 0.164.0"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.164.0", for: "codex-cli 0.165.0"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.166.0-beta.1", for: "codex-cli 0.165.0"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("invalid", for: "0.165.0"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.165.0", for: nil))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.165.0", for: "unknown"))
    }

    func testPrereleaseAndBuildMetadataComparison() {
        XCTAssertTrue(AgentRuntimeVersion.isUpdate("0.165.0", for: "codex-cli 0.165.0-beta.2"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.165.0", for: "codex-cli 0.166.0-beta.2"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.165.0", for: "0.165.0+build-test"))
        XCTAssertFalse(AgentRuntimeVersion.isUpdate("0.165.0+build.2", for: "0.165.0+build.1"))
    }
}
