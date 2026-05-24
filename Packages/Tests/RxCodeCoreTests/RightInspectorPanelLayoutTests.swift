import CoreGraphics
import XCTest
@testable import RxCodeCore

final class RightInspectorPanelLayoutTests: XCTestCase {
    func testRestoredWidthUsesStoredVisibleWidth() {
        let restored = RightInspectorPanelLayout.restoredWidth(from: 680, maxAllowedWidth: 900)

        XCTAssertEqual(restored, 680)
    }

    func testRestoredWidthFallsBackForInvalidStoredWidth() {
        XCTAssertEqual(
            RightInspectorPanelLayout.restoredWidth(from: 0),
            CGFloat(RightInspectorPanelLayout.defaultWidth)
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.restoredWidth(from: RightInspectorPanelLayout.minimumWidth - 1),
            CGFloat(RightInspectorPanelLayout.defaultWidth)
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.restoredWidth(from: .infinity),
            CGFloat(RightInspectorPanelLayout.defaultWidth)
        )
    }

    func testRestoredWidthClampsToAvailableSpace() {
        XCTAssertEqual(
            RightInspectorPanelLayout.restoredWidth(from: 1_000, maxAllowedWidth: 720),
            720
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.restoredWidth(from: 1_000, maxAllowedWidth: 200),
            CGFloat(RightInspectorPanelLayout.minimumWidth)
        )
    }

    func testPersistedWidthStoresOnlyVisiblePanelWidths() {
        XCTAssertEqual(
            RightInspectorPanelLayout.persistedWidth(from: 640, isVisible: true),
            640
        )
        XCTAssertNil(
            RightInspectorPanelLayout.persistedWidth(from: 640, isVisible: false),
            "Hidden split-view measurements must not overwrite the saved inspector width."
        )
        XCTAssertNil(
            RightInspectorPanelLayout.persistedWidth(from: 0, isVisible: true),
            "Collapsed measurements must not overwrite the saved inspector width."
        )
        XCTAssertNil(
            RightInspectorPanelLayout.persistedWidth(from: CGFloat.infinity, isVisible: true)
        )
    }

    func testMaximumWidthLeavesRoomForMainContent() {
        XCTAssertEqual(
            RightInspectorPanelLayout.maximumWidth(in: 1_400),
            920
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.maximumWidth(in: 500),
            CGFloat(RightInspectorPanelLayout.minimumWidth)
        )
    }

    func testResizedWidthUsesLeadingEdgeDragDirectionAndClamps() {
        XCTAssertEqual(
            RightInspectorPanelLayout.resizedWidth(
                startWidth: 640,
                leadingEdgeTranslation: -80,
                maxAllowedWidth: 900
            ),
            720
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.resizedWidth(
                startWidth: 640,
                leadingEdgeTranslation: 80,
                maxAllowedWidth: 900
            ),
            560
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.resizedWidth(
                startWidth: 640,
                leadingEdgeTranslation: 400,
                maxAllowedWidth: 900
            ),
            RightInspectorPanelLayout.minimumWidth
        )
        XCTAssertEqual(
            RightInspectorPanelLayout.resizedWidth(
                startWidth: 640,
                leadingEdgeTranslation: -400,
                maxAllowedWidth: 900
            ),
            900
        )
    }
}
