import RxCodeCore
import SwiftUI
import UIKit
import XCTest

final class TaskPillLayoutTests: XCTestCase {
    @MainActor
    func testLongPillsStayInsideNarrowCards() async throws {
        for width: CGFloat in [200, 320, 600] {
            let frames = try await measurePills(width: width)
            for frame in frames {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            }
            XCTAssertGreaterThan(frames[1].minY, frames[0].minY)
            XCTAssertGreaterThanOrEqual(frames[2].minY, frames[1].maxY)
        }
    }

    @MainActor
    private func measurePills(width: CGFloat) async throws -> [CGRect] {
        let measured = expectation(description: "Pills laid out at \(width) points")
        measured.expectedFulfillmentCount = 3
        var frames: [Int: CGRect] = [:]
        let labels = [
            "Ready",
            "INCOMPLETE: verified working APIs: 0/10; " + String(repeating: "API-2236 evidence/path/", count: 12),
            "Follow-up"
        ]
        let content = FlowLayout(spacing: 4) {
            ForEach(labels.indices, id: \.self) { index in
                TaskPill(text: labels[index], icon: index == 1 ? "tag" : nil)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("card"))
                    } action: { frame in
                        guard frame.width > 0 else { return }
                        let firstMeasurement = frames[index] == nil
                        frames[index] = frame
                        if firstMeasurement { measured.fulfill() }
                    }
            }
        }
        .frame(width: width, alignment: .leading)
        .coordinateSpace(name: "card")
        let host = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [measured], timeout: 5)
        return try labels.indices.map { try XCTUnwrap(frames[$0]) }
    }
}
