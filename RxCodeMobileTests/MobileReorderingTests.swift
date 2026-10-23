import XCTest
@testable import RxCodeMobile

final class MobileReorderingTests: XCTestCase {
    private struct Item: Identifiable {
        let id: Int
    }

    @MainActor
    func testDropUsesLatestIDsAfterConcurrentInsertion() throws {
        let latest = [1, 9, 2, 3, 4].map { Item(id: $0) }
        let moved = try XCTUnwrap(mobileReordered(latest, moving: [1], before: 4))
        XCTAssertEqual(moved.map(\.id), [9, 2, 3, 1, 4])
    }

    @MainActor
    func testMoveToEndAndMultipleSources() throws {
        let items = [1, 2, 3, 4].map { Item(id: $0) }
        XCTAssertEqual(try XCTUnwrap(mobileReordered(items, moving: [1], before: nil)).map(\.id), [2, 3, 4, 1])
        XCTAssertEqual(try XCTUnwrap(mobileReordered(items, moving: [1, 3], before: 4)).map(\.id), [2, 1, 3, 4])
    }

    @MainActor
    func testStaleAndNoOpDropsDoNotChangeOrder() {
        let items = [1, 2, 3].map { Item(id: $0) }
        XCTAssertNil(mobileReordered(items, moving: [1], before: 9))
        XCTAssertNil(mobileReordered(items, moving: [9], before: 2))
        XCTAssertNil(mobileReordered(items, moving: [1], before: 1))
        XCTAssertNil(mobileReordered(items, moving: [1], before: 2))
        XCTAssertNil(mobileReordered(items, moving: [], before: 2))
    }
}
