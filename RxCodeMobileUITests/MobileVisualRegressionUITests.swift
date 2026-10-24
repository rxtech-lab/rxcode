import UIKit
import XCTest

/// The host runner exports these attachments and compares only user-approved baselines.
final class MobileVisualRegressionUITests: XCTestCase {
    @MainActor
    func testSettingsAccountLayouts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-cloud", "-uitest-flowcy", "-flowcy.appearance", "light",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM"
        ]
        app.launch()
        // Keep the ordinary iPhone compact; exercise expanded Duo and iPad layouts.
        let expanded = UIDevice.current.userInterfaceIdiom == .pad
            || ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        XCUIDevice.shared.orientation = expanded ? .landscapeLeft : .portrait
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Settings"].firstMatch.tap()
        let account = app.buttons["flowcy-settings-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        let wide = app.frame.width >= 600
        XCTAssertEqual(account.value as? String, wide ? "Pinned account button" : "Settings menu item")
        if wide {
            XCTAssertGreaterThan(account.frame.midY, app.frame.midY, "Account must remain pinned below the feature list.")
        }
        capture("settings", app: app)

        app.buttons["Integrations"].tap()
        XCTAssertTrue(app.buttons["Notifications"].waitForExistence(timeout: 5))
        if wide {
            // Move focus off the sidebar before capturing its inactive selection.
            app.navigationBars["Integrations"].tap()
        }
        capture("integrations", app: app)
        if wide {
            XCTAssertTrue(account.isHittable, "The fixed account button must survive detail navigation.")
        } else {
            app.navigationBars["Integrations"].buttons.element(boundBy: 0).tap()
        }
        account.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign Out"].exists)
        capture("account", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        // Duo's main screen can be its inactive outer display. Select the lit
        // screen, then render upright to avoid rotated PNG metadata/cropping.
        let images = XCUIScreen.screens.map { $0.screenshot().image }
        let image = images.max { brightness($0) < brightness($1) }!
        XCTAssertGreaterThan(brightness(image), 0.5, "The light-mode UI capture must not be blank.")
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        let attachment = XCTAttachment(image: upright)
        attachment.name = "visual-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func brightness(_ image: UIImage) -> Double {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 16, height: 16,
                bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0) {
            $0 + Int(pixels[$1]) + Int(pixels[$1 + 1]) + Int(pixels[$1 + 2])
        }
        return Double(total) / Double(16 * 16 * 3 * 255)
    }
}
