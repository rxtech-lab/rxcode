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

    @Test(arguments: AppTheme.allCases)
    func textContrast(theme: AppTheme) {
        let colors = theme.colors
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                var environment = EnvironmentValues()
                environment.colorScheme = name == .aqua ? .light : .dark
                let sidebarSelection = composite(colors.sidebarItemSelected, over: colors.sidebarBackground, in: environment)
                if theme == .claude {
                    let orange = Color.hex(0xD97757)
                    #expect(colors.accent.resolve(in: environment) == orange.resolve(in: environment))
                    for tint in [colors.sidebarItemSelected, colors.accentSubtle] {
                        let resolved = tint.resolve(in: environment)
                        #expect(Color(resolved).hexString == "#D97757")
                        #expect(resolved.opacity == (name == .aqua ? 0.12 : 0.15))
                    }
                }
                #expect(contrast(colors.textOnAccent, colors.accent) >= 4.5)
                #expect(contrast(Color(colors.accentText.resolve(in: environment)), colors.surfacePrimary) >= 4.5)
                #expect(contrast(colors.userBubbleText, colors.userBubble) >= 4.5)
                if theme == .rxcode {
                    #expect(contrast(colors.inputBorder, colors.inputBackground) >= 3)
                }
                for background in [colors.background, colors.surfacePrimary, colors.surfaceSecondary,
                                   colors.surfaceTertiary, colors.surfaceElevated, colors.inputBackground,
                                   colors.sidebarBackground, colors.sidebarItemHover, sidebarSelection, colors.assistantBubble,
                                   colors.codeBackground, colors.codeHeaderBackground] {
                    #expect(contrast(colors.textPrimary, background) >= 7)
                    let accentText = colors.semanticForeground(colors.accent, on: background)
                    #expect(contrast(Color(accentText.resolve(in: environment)), background) >= 4.5)
                    for ink in [colors.textSecondary, colors.textTertiary,
                                colors.statusSuccess, colors.statusError, colors.statusWarning] {
                        #expect(contrast(ink, background) >= 4.5)
                    }
                }
                for ink in [colors.textPrimary, colors.textSecondary, colors.textTertiary, colors.accent,
                            colors.statusSuccess, colors.statusError] {
                    let adaptive = colors.foreground(ink)
                    #expect(adaptive.resolve(in: environment) == ink.resolve(in: environment))
                    var selected = environment
                    selected.backgroundProminence = .increased
                    let selection = Color(nsColor: .selectedContentBackgroundColor)
                    #expect(contrast(Color(adaptive.resolve(in: selected)), Color(selection.resolve(in: selected))) >= 4.5)
                }
                for fill in [colors.accent, colors.statusSuccess, colors.statusError, colors.statusWarning] {
                    let ink = colors.foreground(on: fill)
                    #expect(contrast(Color(ink.resolve(in: environment)), fill) >= 4.5)
                    let badge = colors.surfacePrimary.mix(with: fill, by: 0.22)
                    let label = colors.semanticForeground(fill, on: badge)
                    #expect(contrast(Color(label.resolve(in: environment)), badge) >= 4.5)
                }
                for fill in [sidebarSelection, colors.accent] {
                    var row = environment
                    row.themeSelectionBackground = fill
                    let additions = colors.semanticForeground(colors.statusSuccess).resolve(in: row)
                    let deletions = colors.semanticForeground(colors.statusError).resolve(in: row)
                    #expect(additions.green > additions.red && additions.green > additions.blue)
                    #expect(deletions.red > deletions.green && deletions.red > deletions.blue)
                    for ink in [additions, deletions, colors.accentText.resolve(in: row), colors.foreground(colors.textPrimary).resolve(in: row)] {
                        #expect(contrast(Color(ink), fill) >= 4.5)
                    }
                }
                // Sampled native highlights from the Git tree and the chat history.
                for selection in [Color.hex(0x31C89E), Color.hex(0x4DF5C6)] {
                    for ink in [colors.textPrimary, colors.textSecondary, colors.statusSuccess, colors.statusError] {
                        let style = ThemeTextColor(preferred: ink, alternate: colors.textOnAccent, background: selection)
                        #expect(contrast(Color(style.resolve(in: environment)), selection) >= 4.5)
                    }
                }
            }
        }
    }

    @Test func terracottaTextRetainsItsHue() {
        let colors = ThemeColors.claude
        let orange = colors.accent.resolve(in: EnvironmentValues())
        for background in [Color.hex(0x21211E), Color.hex(0xEDEAE0)] {
            let ink = colors.semanticForeground(colors.accent, on: background).resolve(in: EnvironmentValues())
            #expect(ink.red > ink.green && ink.green > ink.blue)
            #expect(contrast(Color(ink), background) >= 4.5)
            if contrast(Color(orange), background) >= 4.5 {
                #expect(ink == orange)
            }
        }
    }

    private func composite(_ overlay: Color, over background: Color, in environment: EnvironmentValues) -> Color {
        let top = overlay.resolve(in: environment)
        let base = background.resolve(in: environment)
        func blend(_ foreground: Float, _ background: Float) -> Double {
            Double(foreground * top.opacity + background * (1 - top.opacity))
        }
        return Color(red: blend(top.red, base.red), green: blend(top.green, base.green), blue: blend(top.blue, base.blue))
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
