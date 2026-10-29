import AppKit
import Observation
import SwiftUI
import Testing
@testable import RxCodeCore

@MainActor
struct ThemeTests {
    @Test func themeChangesInvalidateColorReaders() async {
        let store = ThemeStore.shared
        let previous = store.current
        defer { store.current = previous }
        store.current = .rxcode

        await confirmation("Views reading theme tokens observe palette changes") { changed in
            withObservationTracking {
                _ = ClaudeTheme.background
                _ = ClaudeTheme.accent
            } onChange: {
                changed()
            }
            store.current = .ocean
        }
    }

    @Test func defaultThemeTextContrast() {
        let colors = ThemeColors.rxcode
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                #expect(contrast(colors.textOnAccent, colors.accent) >= 4.5)
                #expect(contrast(colors.inputBorder, colors.inputBackground) >= 3)
                for background in [colors.background, colors.surfacePrimary, colors.surfaceSecondary,
                                   colors.surfaceTertiary, colors.surfaceElevated, colors.inputBackground] {
                    #expect(contrast(colors.textPrimary, background) >= 7)
                    #expect(contrast(colors.textSecondary, background) >= 4.5)
                    #expect(contrast(colors.textTertiary, background) >= 4.5)
                }
            }
        }
    }

    private func contrast(_ foreground: Color, _ background: Color) -> Double {
        let a = luminance(foreground)
        let b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
