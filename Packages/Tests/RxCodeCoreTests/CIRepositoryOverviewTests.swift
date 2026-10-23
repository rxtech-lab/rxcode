import Foundation
import XCTest
@testable import RxCodeCore

final class CIRepositoryOverviewTests: XCTestCase {
    func testPartialOverviewPreservesRepositoryAndAvailableSections() throws {
        let json = #"{"repository":{"id":"watch","installationId":1,"repositoryId":2,"repositoryFullName":"owner/repo"},"history":[],"pullRequests":null,"automation":null,"errors":{"pullRequests":"Unable to load pull requests.","automation":"Unable to load automation."}}"#
        let overview = try JSONDecoder().decode(CIRepositoryOverview.self, from: Data(json.utf8))
        XCTAssertEqual(overview.repository?.fullName, "owner/repo")
        XCTAssertEqual(overview.history?.count, 0)
        XCTAssertNil(overview.pullRequests)
        XCTAssertNil(overview.automation)
        XCTAssertEqual(overview.errors["automation"], "Unable to load automation.")
        let roundTrip = try JSONDecoder().decode(CIRepositoryOverview.self, from: JSONEncoder().encode(overview))
        XCTAssertEqual(roundTrip.repository?.id, "watch")
        XCTAssertEqual(roundTrip.errors, overview.errors)
    }

    func testUnconfiguredRepositoryIsDistinctFromRequestFailure() throws {
        let json = #"{"repository":null,"history":[],"pullRequests":[],"automation":null,"errors":{}}"#
        let overview = try JSONDecoder().decode(CIRepositoryOverview.self, from: Data(json.utf8))
        XCTAssertNil(overview.repository)
        XCTAssertTrue(overview.errors.isEmpty)
    }
}
